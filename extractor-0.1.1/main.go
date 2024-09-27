package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/gnolang/tx-archive/types"
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

	var (
		unwrapFn = func(data types.TxData) []std.Msg {
			return data.Tx.Msgs
		}

		heightFn = func(data types.TxData) uint64 {
			return data.BlockNum
		}

		unwrapLegacyFn = func(tx std.Tx) []std.Msg {
			return tx.Msgs
		}

		heightLegacyFn = func(_ std.Tx) uint64 {
			return 0
		}
	)

	for _, sourceFile := range sourceFiles {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			sourceFile := sourceFile

			// Extract messages
			var (
				msgs       []AddPackage
				processErr error
			)

			if !cfg.legacyMode {
				msgs, processErr = extractAddMessages(
					sourceFile,
					unwrapFn,
					heightFn,
				)
			} else {
				msgs, processErr = extractAddMessages(
					sourceFile,
					unwrapLegacyFn,
					heightLegacyFn,
				)
			}

			if processErr != nil {
				return processErr
			}

			// Process messages
			for _, msg := range msgs {
				outputDir := filepath.Join(cfg.outputDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

				if st, err := os.Stat(outputDir); err == nil && st.IsDir() {
					outputDir += ":" + strconv.FormatUint(msg.Height, 10)
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

// writePackageFiles writes all files from a single package to the output directory
func writePackageFiles(msg AddPackage, outputDir string) error {
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

// AddPackage contains a vm.MsgAddPackage, together with the block height where it appeared.
type AddPackage struct {
	vm.MsgAddPackage
	Height uint64
}

// extractAddMessages extracts the AddPackage messages
func extractAddMessages[T std.Tx | types.TxData](
	filePath string,
	unwrapFn func(T) []std.Msg,
	heightFn func(T) uint64,
) ([]AddPackage, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("unable to open file, %w", err)
	}

	cleanup := func() error {
		if closeErr := file.Close(); closeErr != nil {
			return fmt.Errorf("unable to gracefully close file, %w", closeErr)
		}
		return nil
	}

	reader := bufio.NewReader(file)

	// Msg array to be returned for further processing
	msgArr := make([]AddPackage, 0)

	// Buffer to handle lines longer than 64kb
	tempBuf := make([]byte, 0)

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

		// Handle long lines
		if len(tempBuf) != 0 {
			// Append last part of line to temporary buffer
			tempBuf = append(tempBuf, line...)

			// Use line variable to pass it on to amino
			line = tempBuf
		}

		if err := amino.UnmarshalJSON(line, &txData); err != nil {
			slog.Error("error while parsing amino JSON", "error", err, "line", line)
			continue
		}

		// Reset tempBuf in case it was used for a long line
		if tempBuf != nil {
			tempBuf = nil
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

			msgArr = append(msgArr, AddPackage{
				MsgAddPackage: msgAddPkg,
				Height:        heightFn(txData),
			})
		}
	}

	return msgArr, cleanup()
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
