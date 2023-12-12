package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/peterbourgon/ff/v3/ffcli"
	"golang.org/x/sync/errgroup"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Define constants
const (
	packageMetadataFile = "pkg_metadata.json"
)

// Define extractor config
type extractorCfg struct {
	fileType  string
	sourceDir string
	outputDir string
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
		_, _ = fmt.Fprintf(os.Stderr, "%+v", err)

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
		&c.sourceDir,
		"source-dir",
		".",
		"the root folder containing transaction data",
	)

	fs.StringVar(
		&c.outputDir,
		"output-dir",
		"./extracted",
		"the output directory for the extracted Gno source code",
	)
}

// execExtract runs the extract service for Gno source code
func execExtract(ctx context.Context, cfg *extractorCfg) error {
	// Check the file type is valid
	if cfg.fileType == "" {
		return errors.New("invalid file type specified")
	}

	// Check the source dir is valid
	if cfg.sourceDir == "" {
		return errors.New("invalid source directory")
	}

	// Check the output dir is valid
	if cfg.outputDir == "" {
		return errors.New("invalid output directory")
	}

	// Find the files that need to be analyzed
	sourceFiles, findErr := findFilePaths(cfg.sourceDir, cfg.fileType)
	if findErr != nil {
		return fmt.Errorf("unable to find file paths, %w", findErr)
	}

	// Concurrently process the source files
	g, ctx := errgroup.WithContext(ctx)

	for _, sourceFile := range sourceFiles {
		sourceFile := sourceFile

		g.Go(func() error {
			// Extract messages
			msgs, processErr := extractAddMessages(sourceFile)
			if processErr != nil {
				return processErr
			}

			// Process messages
			for _, msg := range msgs {
				outputDir := filepath.Join(cfg.outputDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

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

			return nil
		})
	}

	return g.Wait()
}

// writePackageFiles writes all files from a single package to the output directory
func writePackageFiles(msg vm.MsgAddPackage, outputDir string) error {
	for _, file := range msg.Package.Files {
		// Get the output path
		writePath := filepath.Join(outputDir, file.Name)

		if writeErr := os.WriteFile(writePath, []byte(file.Body), 0644); writeErr != nil {
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

	if writeErr := os.WriteFile(writePath, metadataRaw, 0644); writeErr != nil {
		return fmt.Errorf("unable to write package metadata, %w", writeErr)
	}

	return nil
}

func extractAddMessages(filePath string) ([]vm.MsgAddPackage, error) {
	file, openErr := os.Open(filePath)
	if openErr != nil {
		return nil, fmt.Errorf("unable to open file, %w", openErr)
	}

	cleanup := func() error {
		if closeErr := file.Close(); closeErr != nil {
			return fmt.Errorf("unable to gracefully close file, %w", closeErr)
		}
		return nil
	}

	reader := bufio.NewReader(file)

	// Used to track what was parsed in the past
	touchMap := make(map[string]vm.MsgAddPackage)

	// Msg array to be returned for further processing
	msgArr := make([]vm.MsgAddPackage, 0)

	// Buffer to handle lines longer than 64kb
	tempBuf := make([]byte, 0)

	i := 0
	for {
		var tx std.Tx
		line, isPrefix, err := reader.ReadLine()

		// Exit if no more lines in file
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
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

		if aminoErr := amino.UnmarshalJSON(line, &tx); aminoErr != nil {
			fmt.Printf("Error while parsing amino JSON at line %d: %v\n", i, aminoErr.Error())
			continue
		}

		// Reset tempBuf in case it was used for a long line
		if tempBuf != nil {
			tempBuf = nil
		}

		for _, msg := range tx.Msgs {
			// Only MsgAddPkg should be parsed
			if msg.Type() != "add_package" {
				continue
			}

			msgAddPkg := msg.(vm.MsgAddPackage)

			path := msgAddPkg.Package.Path

			if _, parsed := touchMap[path]; parsed {
				// Package already parsed
				continue
			}

			touchMap[path] = msgAddPkg
			msgArr = append(msgArr, msgAddPkg)
		}
		i++
	}

	return msgArr, cleanup()
}

// findFilePaths gathers the file paths for specific file types
func findFilePaths(startPath string, fileType string) ([]string, error) {
	filePaths := make([]string, 0)

	walkFn := func(path string, info os.FileInfo, err error) error {
		if err != nil {
			fmt.Println("Error accessing file:", err)
			return err
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
		return nil, fmt.Errorf("unable to walk directory, %v", walkErr)
	}

	return filePaths, nil
}
