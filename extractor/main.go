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
		"flag indicating if the legacy tx sheet mode should be used",
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

	// If source is dir, walk it and add to sourceFiles
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
		unwrapFn = func(data gnoland.TxWithMetadata) []std.Msg {
			return data.Tx.Msgs
		}

		unwrapLegacyFn = func(tx std.Tx) []std.Msg {
			return tx.Msgs
		}

		// deploys counts the deploys of each package dir so far: the first
		// deploy of a path is extracted to its dir, later ones (failed or
		// not: the source files carry no tx results) to <dir>:1, <dir>:2, …
		deploys = make(map[string]int)
	)

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

			if !cfg.legacyMode {
				msgs, processErr = extractAddMessages(sourceFile, unwrapFn)
			} else {
				msgs, processErr = extractAddMessages(sourceFile, unwrapLegacyFn)
			}

			if processErr != nil {
				return processErr
			}

			// Process messages
			for _, msg := range msgs {
				pkgDir := strings.TrimPrefix(msg.Package.Path, "gno.land/")
				if !confined(pkgDir, msg.Package.Files) {
					slog.Warn("skipping a package whose path or file names leave its dir", "path", msg.Package.Path)
					continue
				}
				outputDir := filepath.Join(cfg.outputDir, pkgDir)

				n := deploys[outputDir]
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

// confined reports whether a package is written inside its own dir. Its path
// and file names come from the chain, and the source files keep the txs it
// rejected: the package dir must be a local path below the output dir, without
// the ':' of the numbered dirs, and each file name a plain name inside it.
func confined(pkgDir string, files []*std.MemFile) bool {
	if !filepath.IsLocal(pkgDir) || filepath.Clean(pkgDir) == "." || strings.Contains(pkgDir, ":") {
		return false
	}
	for _, file := range files {
		if file == nil || file.Name != filepath.Base(file.Name) || !filepath.IsLocal(file.Name) || file.Name == "." {
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

// extractAddMessages extracts the MsgAddPackage messages
func extractAddMessages[T std.Tx | gnoland.TxWithMetadata](
	filePath string,
	unwrapFn func(T) []std.Msg,
) (_ []vm.MsgAddPackage, err error) {
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
		var txData T

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

		if err := amino.UnmarshalJSON(line, &txData); err != nil {
			// a deploy the pinned gno types cannot decode fails the run: skipping
			// it would drop its package from a rebuilt tree
			if bytes.Contains(line, []byte(`"/vm.m_addpkg"`)) {
				return nil, fmt.Errorf("%w at %s:%d: %w", errUnparsableDeploy, filePath, lineNum, err)
			}
			slog.Warn("skipping a line the extractor cannot parse", "file", filePath, "line", lineNum, "error", err)
			continue
		}

		for _, msg := range unwrapFn(txData) {
			// Only MsgAddPkg should be parsed
			if msg.Type() != "add_package" {
				continue
			}

			msgAddPkg, ok := msg.(vm.MsgAddPackage)
			if !ok {
				return nil, errors.New("could not cast into MsgAddPackage")
			}

			if msgAddPkg.Package == nil {
				return nil, errors.New("MsgAddPackage is nil")
			}

			msgArr = append(msgArr, msgAddPkg)
		}
	}

	return msgArr, nil
}

// findFilePaths gathers the file paths for specific file types
func findFilePaths(startPath string, fileType string) ([]string, error) {
	filePaths := make([]string, 0)

	walkFn := func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return fmt.Errorf("error accessing file: %w", err)
		}

		// Check if the file is a dir
		if info.IsDir() {
			return nil
		}

		// Check if the file type matches
		if !strings.HasSuffix(info.Name(), fileType) {
			return nil
		}

		// File is not a directory, and is of the type
		filePaths = append(filePaths, path)

		return nil
	}

	// Walk the directory root recursively
	if walkErr := filepath.Walk(startPath, walkFn); walkErr != nil {
		return nil, fmt.Errorf("unable to walk directory, %w", walkErr)
	}

	return filePaths, nil
}
