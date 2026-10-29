package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/gnolang/gno/gno.land/pkg/gnoland"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/peterbourgon/ff/v3/ffcli"
)

// Define constants
const (
	packageMetadataFile = "pkg_metadata.json"
)

var (
	errInvalidFileType    = errors.New("no file type specified")
	errInvalidSourceDir   = errors.New("invalid source directory")
	errInvalidOutputDir   = errors.New("invalid output directory")
	errNoSourceFilesFound = errors.New("no source files found, exiting")
	errOutputDirNotEmpty  = errors.New("output directory is not empty")
	errUnparsableDeploy   = errors.New("unable to parse a /vm.m_addpkg tx")
)

// Define extractor config
type extractorCfg struct {
	fileType   string
	sourcePath string
	outputDir  string

	legacyMode bool
}

func main() {
	var (
		cfg = &extractorCfg{}
		fs  = flag.NewFlagSet("root", flag.ExitOnError)
	)

	// Register the flags
	cfg.registerFlags(fs)

	// Create the command
	cmd := &ffcli.Command{
		ShortUsage: "[flags]",
		LongHelp:   "The Gno / TM2 source code extractor service",
		FlagSet:    fs,
		Exec: func(ctx context.Context, _ []string) error {
			return execExtract(ctx, cfg)
		},
	}

	// Run the command
	if err := cmd.ParseAndRun(context.Background(), os.Args[1:]); err != nil {
		slog.Error("command parse error", "error", err)

		os.Exit(1)
	}
}

// registerFlags registers the extractor service flag set
func (c *extractorCfg) registerFlags(fs *flag.FlagSet) {
	fs.StringVar(
		&c.fileType,
		"file-type",
		".jsonl",
		"the file type for analysis, with a preceding period (ie .jsonl)",
	)

	fs.StringVar(
		&c.sourcePath,
		"source-path",
		"",
		"the source file or folder containing transaction data",
	)

	fs.StringVar(
		&c.outputDir,
		"output-dir",
		"./extracted",
		"the output directory for the extracted Gno source code",
	)

	fs.BoolVar(
		&c.legacyMode,
		"legacy-mode",
		false,
		"read the formats older than {tx, metadata} lines: plain std.Tx (test1) or {tx, blockNum} (test2-test4)",
	)
}

// execExtract runs the extract service for Gno source code
func execExtract(ctx context.Context, cfg *extractorCfg) error {
	// Check the file type is valid
	if cfg.fileType == "" {
		return errInvalidFileType
	}

	// Check the source dir is valid
	if cfg.sourcePath == "" {
		return errInvalidSourceDir
	}

	// Check the output dir is valid
	if cfg.outputDir == "" {
		return errInvalidOutputDir
	}

	// Check if source is valid
	source, err := os.Stat(cfg.sourcePath)
	if err != nil {
		return fmt.Errorf("unable to stat source path, %w", err)
	}

	var sourceFiles []string
	sourceFiles = append(sourceFiles, cfg.sourcePath)

	// If source is dir, list its source files
	if source.IsDir() {
		var findErr error
		sourceFiles, findErr = findFilePaths(cfg.sourcePath, cfg.fileType)
		if findErr != nil {
			return fmt.Errorf("unable to find file paths, %w", findErr)
		}
	}

	if len(sourceFiles) == 0 {
		return errNoSourceFilesFound
	}
	sortByBlockRange(sourceFiles)

	if err := checkOutputDir(cfg.outputDir); err != nil {
		return err
	}

	var (
		decode decodeFn = decodeTx

		// deploys counts the deploys of each package dir so far: the first
		// deploy of a path is extracted to its dir, later ones (failed or
		// not: the source files carry no tx results) to <dir>:1, <dir>:2, …
		deploys = make(map[string]int)
	)
	if cfg.legacyMode {
		decode = decodeLegacy
	}

	for _, sourceFile := range sourceFiles {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			sourceFile := sourceFile

			// Extract messages
			var (
				msgs       []vm.MsgAddPackage
				processErr error
			)

			msgs, processErr = extractAddMessages(sourceFile, decode)

			if processErr != nil {
				return processErr
			}

			// Process messages
			for _, msg := range msgs {
				pkgDir := strings.TrimPrefix(msg.Package.Path, "gno.land/")
				if !writable(pkgDir, msg.Package.Files) {
					slog.Warn("skipping a package whose path or file names cannot be written", "path", msg.Package.Path)
					continue
				}
				outputDir := filepath.Join(cfg.outputDir, pkgDir)

				n, ok := placeDeploy(cfg.outputDir, outputDir, deploys[outputDir], msg.Package.Files)
				if !ok {
					slog.Warn("skipping a deploy that no numbered dir can hold", "path", msg.Package.Path)
					continue
				}
				if n != deploys[outputDir] {
					slog.Warn("moving a deploy past what an earlier one wrote", "path", msg.Package.Path, "number", n)
				}
				deploys[outputDir] = n + 1
				if n > 0 {
					outputDir += ":" + strconv.Itoa(n)
				}

				// Write dir before writing files
				if dirWriteErr := os.MkdirAll(outputDir, os.ModePerm); dirWriteErr != nil {
					return fmt.Errorf("unable to write dir, %w", dirWriteErr)
				}

				// Write the package source code
				if writeErr := writePackageFiles(msg, outputDir); writeErr != nil {
					return writeErr
				}

				// Write the package metadata
				if writeErr := writePackageMetadata(metadataFromMsg(msg), outputDir); writeErr != nil {
					return writeErr
				}
			}
		}
	}

	return nil
}

// maxNameLen is the longest file or dir name the filesystem takes, in bytes.
const maxNameLen = 255

// writable reports whether a package's path and file names can be written as
// its dir and files. They come from the chain, and the source files keep the
// txs it rejected, so a name the chain refuses must neither escape nor fail the
// run. The package dir must be a local path below the output dir; each file
// name a plain name inside it; neither may hold a NUL, the ':' of the numbered
// dirs, or a name longer than the filesystem takes; and no file may be named
// like the metadata file.
func writable(pkgDir string, files []*std.MemFile) bool {
	if !filepath.IsLocal(pkgDir) || filepath.Clean(pkgDir) == "." || strings.ContainsAny(pkgDir, ":\x00") {
		return false
	}
	for _, part := range strings.Split(pkgDir, "/") {
		if len(part) > maxNameLen {
			return false
		}
	}
	for _, file := range files {
		if file == nil || file.Name != filepath.Base(file.Name) || !filepath.IsLocal(file.Name) || file.Name == "." ||
			strings.ContainsAny(file.Name, ":\x00") || len(file.Name) > maxNameLen || file.Name == packageMetadataFile {
			return false
		}
	}
	return true
}

// placeDeploy picks the number of a package's next deploy: n, or the first one
// after it whose dir (dir, or dir:<number>) the earlier deploys left free. One
// deploy's file can stand where another needs a dir: a package r/x with a file
// named license, and a package r/x/license. It reports false when no number
// helps: a file stands on the way to dir, or the numbered name is longer than
// the filesystem takes.
func placeDeploy(root, dir string, n int, files []*std.MemFile) (int, bool) {
	rel, err := filepath.Rel(root, filepath.Dir(dir))
	if err != nil {
		return 0, false
	}
	way := root
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		way = filepath.Join(way, part)
		if info, err := os.Lstat(way); err == nil && !info.IsDir() {
			return 0, false
		}
	}

	for ; ; n++ {
		candidate := dir
		if n > 0 {
			candidate += ":" + strconv.Itoa(n)
		}
		if len(filepath.Base(candidate)) > maxNameLen {
			return 0, false
		}
		if free(candidate, files) {
			return n, true
		}
	}
}

// free reports whether a deploy can be written in dir: dir is absent, or a dir
// in which none of the deploy's files, nor its metadata file, is a dir.
func free(dir string, files []*std.MemFile) bool {
	info, err := os.Lstat(dir)
	if err != nil {
		return true
	}
	if !info.IsDir() {
		return false
	}
	names := []string{packageMetadataFile}
	for _, file := range files {
		names = append(names, file.Name)
	}
	for _, name := range names {
		if info, err := os.Lstat(filepath.Join(dir, name)); err == nil && info.IsDir() {
			return false
		}
	}
	return true
}

// writePackageFiles writes all files from a single package to the output directory
func writePackageFiles(msg vm.MsgAddPackage, outputDir string) error {
	for _, file := range msg.Package.Files {
		// Get the output path
		writePath := filepath.Join(outputDir, file.Name)

		if writeErr := os.WriteFile(writePath, []byte(file.Body), 0o644); writeErr != nil {
			return fmt.Errorf("unable to write file %s, %w", file.Name, writeErr)
		}
	}

	return nil
}

// writePackageMetadata writes the package metadata to the output directory
func writePackageMetadata(metadata Metadata, outputDir string) error {
	// Get the output path
	writePath := filepath.Join(outputDir, packageMetadataFile)

	// Get the JSON metadata
	metadataRaw, marshalErr := json.Marshal(metadata)
	if marshalErr != nil {
		return fmt.Errorf("unable to JSON marshal metadata, %w", marshalErr)
	}

	if writeErr := os.WriteFile(writePath, metadataRaw, 0o644); writeErr != nil {
		return fmt.Errorf("unable to write package metadata, %w", writeErr)
	}

	return nil
}

// checkOutputDir refuses an output directory that exists and is not empty:
// extraction never mixes with an earlier tree, so each run's numbering of
// repeated deploys stands on its own. A missing output directory is created
// only when the first package is written: `make extractor` relies on that to
// tell a run that wrote nothing.
func checkOutputDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("unable to read output directory, %w", err)
	}
	if len(entries) > 0 {
		return fmt.Errorf("%w: %s", errOutputDirNotEmpty, dir)
	}
	return nil
}

// blockRange matches the range at the end of a source file name
// (backup_<from>-<to>.jsonl), capturing <from>.
var blockRange = regexp.MustCompile(`(\d+)-\d+\.[^./]+$`)

// sortByBlockRange orders source files by the start of the range in their
// name (blocks, or lines for staging's chunks), so packages are extracted in
// chain order: staging's ranges are not zero-padded, so a lexical order would
// not be the chain order. Names without a range sort lexically, after those
// with one.
func sortByBlockRange(paths []string) {
	from := func(path string) (uint64, bool) {
		m := blockRange.FindStringSubmatch(filepath.Base(path))
		if m == nil {
			return 0, false
		}
		n, err := strconv.ParseUint(m[1], 10, 64)
		return n, err == nil
	}

	sort.SliceStable(paths, func(i, j int) bool {
		fi, oki := from(paths[i])
		fj, okj := from(paths[j])
		switch {
		case oki && okj && fi != fj:
			return fi < fj
		case oki != okj:
			return oki
		default:
			return paths[i] < paths[j]
		}
	})
}

// extractAddMessages extracts the MsgAddPackage messages of a source file,
// decoding each line with decode
func extractAddMessages(filePath string, decode decodeFn) (_ []vm.MsgAddPackage, err error) {
	file, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("unable to open file, %w", err)
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("unable to gracefully close file, %w", closeErr))
		}
	}()

	reader := bufio.NewReader(file)

	// Msg array to be returned for further processing
	msgArr := make([]vm.MsgAddPackage, 0)

	// Buffer for lines longer than the reader's 4096-byte buffer
	tempBuf := make([]byte, 0)

	// Number of the line being parsed, for logs
	lineNum := 0

	for {
		line, isPrefix, err := reader.ReadLine()

		// Exit if no more lines in file
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("error reading lines; %w", err)
		}

		// If line is too long, save it in a temporary buffer and continue reading line
		if isPrefix {
			tempBuf = append(tempBuf, line...)
			continue
		}

		// Handle long lines: the buffer holds the line's earlier parts, and is
		// emptied before parsing so a line that is skipped cannot leak into the next
		if len(tempBuf) != 0 {
			line = append(tempBuf, line...)
			tempBuf = nil
		}
		lineNum++

		deploys, err := decode(line)
		if err != nil {
			// a deploy the extractor cannot decode fails the run: skipping it
			// would drop its package from a rebuilt tree
			if bytes.Contains(line, []byte(`"/vm.m_addpkg"`)) {
				return nil, fmt.Errorf("%w at %s:%d: %w", errUnparsableDeploy, filePath, lineNum, err)
			}
			slog.Warn("skipping a line the extractor cannot parse", "file", filePath, "line", lineNum, "error", err)
			continue
		}
		msgArr = append(msgArr, deploys...)
	}

	return msgArr, nil
}

// decodeFn decodes the deploys of one source line.
type decodeFn func(line []byte) ([]vm.MsgAddPackage, error)

// decodeTx decodes a {tx, metadata} line with the pinned gno types.
func decodeTx(line []byte) ([]vm.MsgAddPackage, error) {
	var data gnoland.TxWithMetadata
	if err := amino.UnmarshalJSON(line, &data); err != nil {
		return nil, err
	}

	var deploys []vm.MsgAddPackage
	for _, msg := range data.Tx.Msgs {
		// Only MsgAddPkg should be parsed
		if msg.Type() != "add_package" {
			continue
		}

		deploy, ok := msg.(vm.MsgAddPackage)
		if !ok {
			return nil, errors.New("could not cast into MsgAddPackage")
		}

		if deploy.Package == nil {
			return nil, errors.New("MsgAddPackage is nil")
		}

		deploys = append(deploys, deploy)
	}

	return deploys, nil
}

// legacyLine is a source line in a format older than {tx, metadata}: a plain
// std.Tx (test1) or a {tx, blockNum} object (test2-test4).
type legacyLine struct {
	Msg []json.RawMessage `json:"msg"`
	Tx  *struct {
		Msg []json.RawMessage `json:"msg"`
	} `json:"tx"`
}

// legacyDeploy is a /vm.m_addpkg message in those formats: its deposit is under
// `deposit`, and test1-test3 capitalize the package keys, which encoding/json
// matches case-insensitively. It lists every key they carry: any other one
// fails the decoding rather than being misread.
type legacyDeploy struct {
	Type    string `json:"@type"`
	Creator string `json:"creator"`
	Deposit string `json:"deposit"`
	Package *struct {
		Name  string `json:"name"`
		Path  string `json:"path"`
		Files []*struct {
			Name string `json:"name"`
			Body string `json:"body"`
		} `json:"files"`
	} `json:"package"`
}

// decodeLegacy decodes the deploys of a line in a format older than
// {tx, metadata}. It does not use the pinned gno types, whose amino JSON
// rejects these formats' fields and key casing.
func decodeLegacy(line []byte) ([]vm.MsgAddPackage, error) {
	var parsed legacyLine
	if err := json.Unmarshal(line, &parsed); err != nil {
		return nil, err
	}
	msgs := parsed.Msg
	if parsed.Tx != nil {
		msgs = parsed.Tx.Msg
	}

	var deploys []vm.MsgAddPackage
	for _, raw := range msgs {
		var head struct {
			Type string `json:"@type"`
		}
		if err := json.Unmarshal(raw, &head); err != nil {
			return nil, err
		}
		if head.Type != "/vm.m_addpkg" {
			continue
		}

		var msg legacyDeploy
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&msg); err != nil {
			return nil, err
		}
		if msg.Package == nil {
			return nil, errors.New("MsgAddPackage is nil")
		}
		creator, err := crypto.AddressFromBech32(msg.Creator)
		if err != nil {
			return nil, fmt.Errorf("invalid deploy creator, %w", err)
		}
		deposit, err := std.ParseCoins(msg.Deposit)
		if err != nil {
			return nil, fmt.Errorf("invalid deploy deposit, %w", err)
		}
		files := make([]*std.MemFile, len(msg.Package.Files))
		for i, file := range msg.Package.Files {
			if file != nil {
				files[i] = &std.MemFile{Name: file.Name, Body: file.Body}
			}
		}

		deploys = append(deploys, vm.MsgAddPackage{
			Creator: creator,
			Send:    deposit,
			Package: &std.MemPackage{Name: msg.Package.Name, Path: msg.Package.Path, Files: files},
		})
	}

	return deploys, nil
}

// findFilePaths lists the files of a type directly in a dir. Its subdirs are
// skipped: a chain dir's extracted/ tree holds package files, not source files.
func findFilePaths(dir string, fileType string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("unable to read directory, %w", err)
	}

	filePaths := make([]string, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), fileType) {
			continue
		}
		filePaths = append(filePaths, filepath.Join(dir, entry.Name()))
	}

	return filePaths, nil
}
