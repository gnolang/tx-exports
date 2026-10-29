package main

import (
	"bufio"
	"bytes"
	"context"
	crand "crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log"
	"log/slog"
	"math/rand"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gnolang/gno/gno.land/pkg/gnoland"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const sourceFileType = ".jsonl"

func TestExtractor_Errors(t *testing.T) {
	testTable := []struct {
		name        string
		cfg         *extractorCfg
		expectedErr error
	}{
		{
			"no source files",
			&extractorCfg{
				fileType:   ".log",
				sourcePath: "./",
				outputDir:  ".",
			},
			errNoSourceFilesFound,
		},
		{
			"invalid filetype",
			&extractorCfg{
				fileType:   "",
				sourcePath: ".",
				outputDir:  ".",
			},
			errInvalidFileType,
		},
		{
			"invalid source dir",
			&extractorCfg{
				fileType:   ".log",
				sourcePath: "",
				outputDir:  ".",
			},
			errInvalidSourceDir,
		},
		{
			"invalid output dir",
			&extractorCfg{
				fileType:   ".log",
				sourcePath: ".",
				outputDir:  "",
			},
			errInvalidOutputDir,
		},
	}

	for _, testCase := range testTable {
		testCase := testCase

		t.Run(testCase.name, func(t *testing.T) {
			t.Parallel()

			ctx := context.Background()

			err := execExtract(ctx, testCase.cfg)
			assert.ErrorIs(t, err, testCase.expectedErr)
		})
	}
}

func TestValidFlow_Dir(t *testing.T) {
	t.Parallel()

	// Generate temporary output dir
	outputDir, err := os.MkdirTemp(".", "outputDir")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, outputDir))

	// Generate temporary source dir
	sourceDir, err := os.MkdirTemp(".", "sourceDir")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, sourceDir))

	// Set correct config
	cfg := &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}

	// Generate mock messages & mock files
	mockStdMsg, mockAddPkgMsg := generateMockMsgs(t)
	_ = generateSourceFiles(t, sourceDir, mockStdMsg, 20)

	// Perform extraction
	ctx := context.Background()

	require.NoError(t, execExtract(ctx, cfg))

	for _, msg := range mockAddPkgMsg {
		basePath := filepath.Join(outputDir, strings.TrimPrefix(msg.Package.Path, "gno.land/"))

		// Get metadata path & open metadata file
		metadataPath := filepath.Join(basePath, packageMetadataFile)
		file, err := os.Open(metadataPath)
		require.NoError(t, err)

		// Read Metadata
		reader := bufio.NewReader(file)
		retrievedMetadata, _, err := reader.ReadLine()
		require.NoError(t, err)

		// Compare metadata
		expectedMetadata, err := json.Marshal(metadataFromMsg(msg))
		require.NoError(t, err)
		assert.Equal(t, expectedMetadata, retrievedMetadata)

		// Close metadata file
		require.NoError(t, file.Close())

		// Check package file content
		for _, f := range msg.Package.Files {
			filePath := filepath.Join(basePath, f.Name)

			// Open file
			file, err := os.Open(filePath)
			require.NoError(t, err)

			// Read file body
			reader := bufio.NewReader(file)
			retrievedFileBody, _, err := reader.ReadLine()

			// Compare file bodies
			assert.Equal(t, f.Body, string(retrievedFileBody))
		}
	}
}

func TestValidFlow_File(t *testing.T) {
	t.Parallel()

	// Generate temporary output dir
	outputDir, err := os.MkdirTemp(".", "outputDir")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, outputDir))

	// Generate temporary source dir
	sourceDir, err := os.MkdirTemp(".", "sourceDir")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, sourceDir))

	// Set correct config
	cfg := &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}

	// Generate mock messages & mock files
	mockStdMsg, mockAddPkgMsg := generateMockMsgs(t)
	_ = generateSourceFiles(t, sourceDir, mockStdMsg, 1)

	// Perform extraction
	ctx := context.Background()

	require.NoError(t, execExtract(ctx, cfg))

	for _, msg := range mockAddPkgMsg {
		basePath := filepath.Join(outputDir, strings.TrimPrefix(msg.Package.Path, "gno.land/"))

		// Get metadata path & open metadata file
		metadataPath := filepath.Join(basePath, packageMetadataFile)
		file, err := os.Open(metadataPath)
		require.NoError(t, err)

		// Read Metadata
		reader := bufio.NewReader(file)
		retrievedMetadata, _, err := reader.ReadLine()
		require.NoError(t, err)

		// Compare metadata
		expectedMetadata, err := json.Marshal(metadataFromMsg(msg))
		require.NoError(t, err)
		assert.Equal(t, expectedMetadata, retrievedMetadata)

		// Close metadata file
		require.NoError(t, file.Close())

		// Check package file content
		for _, f := range msg.Package.Files {
			filePath := filepath.Join(basePath, f.Name)

			// Open file
			file, err := os.Open(filePath)
			require.NoError(t, err)

			// Read file body
			reader := bufio.NewReader(file)
			retrievedFileBody, _, err := reader.ReadLine()

			// Compare file bodies
			assert.Equal(t, f.Body, string(retrievedFileBody))
		}
	}
}

func TestFindFilePaths(t *testing.T) {
	t.Parallel()

	tempDir, err := os.MkdirTemp(".", "test")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, tempDir))

	numSourceFiles := 20
	testFiles := make([]string, numSourceFiles)

	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = "sourceFile" + strconv.Itoa(i) + sourceFileType
	}

	for _, file := range testFiles {
		filePath := filepath.Join(tempDir, file)
		err := os.MkdirAll(filepath.Dir(filePath), os.ModePerm)
		require.NoError(t, err)

		_, err = os.Create(filePath)
		require.NoError(t, err)
	}

	results, err := findFilePaths(tempDir, sourceFileType)
	require.NoError(t, err)

	expectedResults := make([]string, 0, len(testFiles))

	for _, testFile := range testFiles {
		expectedResults = append(expectedResults, filepath.Join(tempDir, testFile))
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i] < results[j]
	})

	sort.Slice(expectedResults, func(i, j int) bool {
		return expectedResults[i] < expectedResults[j]
	})

	require.Equal(t, len(results), len(expectedResults))

	for i, result := range results {
		if result != expectedResults[i] {
			require.Equal(t, result, expectedResults[i])
		}
	}
}

func TestExtractAddMessages(t *testing.T) {
	t.Parallel()

	tempDir, err := os.MkdirTemp(".", "test")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, tempDir))

	mockMsgs, mockMsgsAddPackage := generateMockMsgs(t)
	sourceFiles := generateSourceFiles(t, tempDir, mockMsgs, 20)

	var results []vm.MsgAddPackage
	for _, sf := range sourceFiles {
		res, err := extractAddMessages(sf, decodeTx)
		require.NoError(t, err)
		results = append(results, res...)
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].Package.Name < results[j].Package.Name
	})
	sort.Slice(mockMsgsAddPackage, func(i, j int) bool {
		return mockMsgsAddPackage[i].Package.Name < mockMsgsAddPackage[j].Package.Name
	})

	require.Equal(t, results, mockMsgsAddPackage)
}

func TestWritePackageMetadata(t *testing.T) {
	t.Parallel()

	_, mockMsgsAddPackage := generateMockMsgs(t)

	// Make temp dir
	tempDir, err := os.MkdirTemp(".", "test")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, tempDir))

	for _, msg := range mockMsgsAddPackage {
		md := metadataFromMsg(msg)

		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimPrefix(msg.Package.Path, "gno.land/"))

		// Write dir before writing metadata
		err := os.MkdirAll(outputDir, os.ModePerm)
		require.NoError(t, err)

		// Write the metadata
		err = writePackageMetadata(md, outputDir)
		require.NoError(t, err)

		// Read file
		file, err := os.Open(filepath.Join(outputDir, packageMetadataFile))
		require.NoError(t, err)

		reader := bufio.NewReader(file)
		var unmarshalledMetadata Metadata

		raw, isPrefix, err := reader.ReadLine()
		require.NoError(t, err)
		require.Equal(t, isPrefix, false)

		err = json.Unmarshal(raw, &unmarshalledMetadata)
		require.NoError(t, err)

		require.Equal(t, md, unmarshalledMetadata)
	}
}

func TestWritePackageFiles(t *testing.T) {
	t.Parallel()

	_, mockMsgsAddPackage := generateMockMsgs(t)

	tempDir, err := os.MkdirTemp(".", "test")
	require.NoError(t, err)
	t.Cleanup(removeDir(t, tempDir))

	for _, msg := range mockMsgsAddPackage {
		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimPrefix(msg.Package.Path, "gno.land/"))

		// Write dir before writing metadata
		err := os.MkdirAll(outputDir, os.ModePerm)
		require.NoError(t, err)

		// Write the metadata
		err = writePackageFiles(msg, outputDir)
		require.NoError(t, err)

		// Read & compare file
		for _, f := range msg.Package.Files {
			contents, err := os.ReadFile(filepath.Join(outputDir, f.Name))
			require.NoError(t, err)
			require.Equal(t, f.Body, string(contents))
		}
	}
}

func TestExtract_NumbersRepeatedDeploysInChainOrder(t *testing.T) {
	t.Parallel()

	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgTx(t, "gno.land/r/demo/x", "first"),
		addPkgTx(t, "gno.land/r/demo/y", "only"),
	)
	writeSourceFile(t, sourceDir, "backup_0000011-0000020.jsonl",
		addPkgTx(t, "gno.land/r/demo/x", "second"),
		addPkgTx(t, "gno.land/r/demo/x", "third"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x", "x:1", "x:2", "y"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, "first", readPkgBody(t, outputDir, "r/demo/x"))
	assert.Equal(t, "second", readPkgBody(t, outputDir, "r/demo/x:1"))
	assert.Equal(t, "third", readPkgBody(t, outputDir, "r/demo/x:2"))
	assert.Equal(t, "only", readPkgBody(t, outputDir, "r/demo/y"))
}

func TestExtract_ReadsSourceFilesInBlockOrder(t *testing.T) {
	t.Parallel()

	// staging's chunk names are not zero-padded: lexically, 10001-11000
	// sorts before 1001-2000
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_staging_txs_10001-11000.jsonl", addPkgTx(t, "gno.land/r/demo/x", "third"))
	writeSourceFile(t, sourceDir, "backup_staging_txs_1001-2000.jsonl", addPkgTx(t, "gno.land/r/demo/x", "second"))
	writeSourceFile(t, sourceDir, "backup_staging_txs_1-1000.jsonl", addPkgTx(t, "gno.land/r/demo/x", "first"))

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, "first", readPkgBody(t, outputDir, "r/demo/x"))
	assert.Equal(t, "second", readPkgBody(t, outputDir, "r/demo/x:1"))
	assert.Equal(t, "third", readPkgBody(t, outputDir, "r/demo/x:2"))
}

func TestExtract_NumbersRepeatedDeploysInLegacyMode(t *testing.T) {
	t.Parallel()

	// test1's plain std.Tx lines, with its capitalized package keys
	deploy := func(body string) string {
		return `{"msg":[{"@type":"/vm.m_addpkg",` + legacyCreator + `,"deposit":"",` +
			`"package":{"Name":"x","Path":"gno.land/r/demo/x","Files":[{"Name":"x.gno","Body":"` + body + `"}]}}],` +
			`"fee":{"gas_wanted":"1","gas_fee":"1gnot"},"signatures":null,"memo":""}`
	}
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeLines(t, sourceDir, "txexport-aa.log", deploy("first"), deploy("second"))

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   ".log",
		sourcePath: sourceDir,
		outputDir:  outputDir,
		legacyMode: true,
	}))

	assert.Equal(t, []string{"x", "x:1"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, "first", readPkgBody(t, outputDir, "r/demo/x"))
	assert.Equal(t, "second", readPkgBody(t, outputDir, "r/demo/x:1"))
}

func TestExtract_RefusesANonEmptyOutputDir(t *testing.T) {
	t.Parallel()

	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl", addPkgTx(t, "gno.land/r/demo/x", "new"))
	require.NoError(t, os.WriteFile(filepath.Join(outputDir, "keep"), []byte("old"), 0o644))

	err := execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	})

	assert.ErrorIs(t, err, errOutputDirNotEmpty)
	assert.Equal(t, []string{"keep"}, dirNames(t, outputDir))
}

func TestExtract_CreatesAMissingOutputDir(t *testing.T) {
	t.Parallel()

	sourceDir := t.TempDir()
	outputDir := filepath.Join(t.TempDir(), "extracted.new")
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl", addPkgTx(t, "gno.land/r/demo/x", "new"))

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, "new", readPkgBody(t, outputDir, "r/demo/x"))
}

func TestExtract_FailsOnADeployItCannotParse(t *testing.T) {
	t.Parallel()

	// a deploy with a field the pinned gno types do not know, as after a chain
	// upgrade: skipping it would drop its package from the rebuilt tree
	sourceDir := t.TempDir()
	unknownField := mustReplace(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/y", "y")),
		`"path":"gno.land/r/demo/y"`, `"path":"gno.land/r/demo/y","newfield":1`)
	writeLines(t, sourceDir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "x")),
		unknownField,
	)

	err := execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  filepath.Join(t.TempDir(), "extracted.new"),
	})

	assert.ErrorIs(t, err, errUnparsableDeploy)
}

func TestExtract_SkipsAnUnparsableLineWithoutADeploy(t *testing.T) {
	t.Parallel()

	// a msg type the pinned gno types do not know (such as vm.m_enable_pkg) in
	// a tx without a deploy: there is no package to lose, even if its memo
	// mentions /vm.m_addpkg
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	unknownType := mustReplace(t, mustReplace(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/z", "z")),
		`"/vm.m_addpkg"`, `"/vm.m_unknown"`), `"memo":""`, `"memo":"not a /vm.m_addpkg"`)
	writeLines(t, sourceDir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "x")),
		unknownType,
		txJSON(t, addPkgTx(t, "gno.land/r/demo/y", "y")),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x", "y"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
}

func TestExtract_ReadsPastALongLineItSkips(t *testing.T) {
	t.Parallel()

	// an undecodable line without a deploy, longer than the reader's 4096-byte
	// buffer: skipping it must not carry its bytes into the next line
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	long := mustReplace(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/z", strings.Repeat("z", 8192))),
		`"/vm.m_addpkg"`, `"/vm.m_unknown"`)
	writeLines(t, sourceDir, "backup_0000001-0000010.jsonl",
		long,
		txJSON(t, addPkgTx(t, "gno.land/r/demo/y", "y")),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, "y", readPkgBody(t, outputDir, "r/demo/y"))
}

func TestExtractAddMessages_ClosesTheFileOnAnError(t *testing.T) {
	// not parallel: it counts the process's open file descriptors, and with
	// the GC off, since a collected *os.File closes itself
	defer debug.SetGCPercent(debug.SetGCPercent(-1))

	nilPackage := txJSON(t, gnoland.TxWithMetadata{Tx: std.Tx{Msgs: []std.Msg{vm.MsgAddPackage{
		Creator: addressFromString(t, "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
	}}}})
	dir := t.TempDir()
	writeLines(t, dir, "backup_0000001-0000010.jsonl", nilPackage)

	before := openFiles(t)
	for range 20 {
		_, err := extractAddMessages(filepath.Join(dir, "backup_0000001-0000010.jsonl"), decodeTx)
		require.Error(t, err)
	}

	assert.Equal(t, before, openFiles(t))
}

func TestExtractAddMessages_LogsASkippedLineByNumber(t *testing.T) {
	// not parallel: it swaps the default logger
	logs := captureLogs(t)

	unknownType := mustReplace(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/z", "the-skipped-line")),
		`"/vm.m_addpkg"`, `"/vm.m_unknown"`)
	dir := t.TempDir()
	writeLines(t, dir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "x")),
		unknownType,
	)

	_, err := extractAddMessages(filepath.Join(dir, "backup_0000001-0000010.jsonl"), decodeTx)
	require.NoError(t, err)

	assert.Contains(t, logs.String(), "backup_0000001-0000010.jsonl")
	assert.Contains(t, logs.String(), "line=2")
	assert.NotContains(t, logs.String(), "the-skipped-line")
}

func TestExtract_TrimsOnlyTheGnoLandPrefix(t *testing.T) {
	t.Parallel()

	// "gno.land/" is a prefix, not a set of characters: test2 has packages
	// under github.com/
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgTx(t, "gno.land/r/demo/x", "x"),
		addPkgTx(t, "github.com/gnolang/y", "y"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, "x", readPkgBody(t, outputDir, "r/demo/x"))
	assert.Equal(t, "y", readPkgBody(t, outputDir, "github.com/gnolang/y"))
}

func TestExtract_SkipsPackagesThatLeaveTheirDir(t *testing.T) {
	t.Parallel()

	// package paths and file names come from the chain, and the backups keep
	// the txs it rejected: none may write outside its package dir, or into a
	// numbered dir (':')
	withFile := func(path, name string) string {
		tx := addPkgTx(t, path, "bad")
		tx.Tx.Msgs[0].(vm.MsgAddPackage).Package.Files[0].Name = name
		return txJSON(t, tx)
	}
	sourceDir, root := t.TempDir(), t.TempDir()
	outputDir := filepath.Join(root, "chain", "extracted")
	writeLines(t, sourceDir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "first")),
		// from root/chain/extracted, these land in root, where the walk below looks
		txJSON(t, addPkgTx(t, "gno.land/r/../../../escaped", "bad")),
		txJSON(t, addPkgTx(t, "gno.land/r/..", "bad")),
		txJSON(t, addPkgTx(t, "gno.land/.", "bad")),
		txJSON(t, addPkgTx(t, "gno.land//abs", "bad")),
		withFile("gno.land/r/demo/y", "../../../../../escaped.gno"),
		withFile("gno.land/r/demo/y", "sub/x.gno"),
		withFile("gno.land/r/demo/y", ".."),
		withFile("gno.land/r/demo/y", "."),
		mustReplace(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/y", "bad")),
			`"files":[{"name":"x.gno","body":"bad"}]`, `"files":[null]`),
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "second")),
		// after x's second deploy, so writing it would overwrite r/demo/x:1
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x:1", "bad")),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	var written []string
	require.NoError(t, filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			rel, _ := filepath.Rel(root, path)
			written = append(written, filepath.ToSlash(rel))
		}
		return err
	}))
	assert.Equal(t, []string{
		"chain/extracted/r/demo/x/pkg_metadata.json",
		"chain/extracted/r/demo/x/x.gno",
		"chain/extracted/r/demo/x:1/pkg_metadata.json",
		"chain/extracted/r/demo/x:1/x.gno",
	}, written)
	assert.Equal(t, "second", readPkgBody(t, outputDir, "r/demo/x:1"))
}

func TestExtract_SkipsPackagesWithNamesItCannotWrite(t *testing.T) {
	// not parallel: it captures the default logger
	logs := captureLogs(t)

	// names inside the output dir that a write would still fail on, or that
	// would clash with what the extractor writes: the run must go on
	long := strings.Repeat("l", 256)
	withFile := func(path, name string) gnoland.TxWithMetadata {
		tx := addPkgTx(t, path, "bad")
		tx.Tx.Msgs[0].(vm.MsgAddPackage).Package.Files[0].Name = name
		return tx
	}
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgTx(t, "gno.land/r/demo/nul\x00path", "bad"),
		withFile("gno.land/r/demo/a", "nul\x00name.gno"),
		withFile("gno.land/r/demo/b", "colon:1"),
		withFile("gno.land/r/demo/c", packageMetadataFile),
		addPkgTx(t, "gno.land/r/demo/"+long, "bad"),
		withFile("gno.land/r/demo/d", long+".gno"),
		addPkgTx(t, "gno.land/r/demo/x", "x"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, 6, strings.Count(logs.String(), "skipping a package"))
}

func TestExtract_SkipsPackagesWithNamesGitRefuses(t *testing.T) {
	// not parallel: it captures the default logger
	logs := captureLogs(t)

	// names git refuses to add (.git in any case or spelling, 8.3 short names,
	// a backslash form) or that hide files from it (.gitignore): the exporter's
	// commit would fail, or drop packages
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgTx(t, "gno.land/r/demo/.GIT", "bad"),
		addPkgTx(t, "gno.land/r/demo/.git/x", "bad"),
		addPkgFileTx(t, "gno.land/r/demo/a", "git~1", "bad"),
		addPkgFileTx(t, "gno.land/r/demo/b", ".git.", "bad"),
		addPkgFileTx(t, "gno.land/r/demo/c", `a\.git`, "bad"),
		addPkgFileTx(t, "gno.land/r/demo/d", ".gitignore", "*"),
		addPkgFileTx(t, "gno.land/r/demo/e", ".git", "bad"),
		addPkgTx(t, "gno.land/r/demo/x", "x"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, 7, strings.Count(logs.String(), "skipping a package"))
}

func TestExtract_SkipsADeployWhosePathIsTooLong(t *testing.T) {
	// not parallel: it captures the default logger
	logs := captureLogs(t)

	// every component fits, but not the whole path (Linux takes 4,095 bytes)
	long := strings.TrimSuffix(strings.Repeat(strings.Repeat("l", 250)+"/", 17), "/")
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgTx(t, "gno.land/r/demo/"+long, "bad"),
		addPkgTx(t, "gno.land/r/demo/x", "x"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, 1, strings.Count(logs.String(), "skipping a deploy"))
}

func TestExtract_MovesADeployPastWhatAnEarlierOneWrote(t *testing.T) {
	t.Parallel()

	// a package's file where a later deploy needs a dir, or the reverse: the
	// later deploy moves to its path's next free number
	for name, tc := range map[string]struct {
		deploys []gnoland.TxWithMetadata
		files   map[string]string // file under the output dir: body
	}{
		"a file, then a package at its path": {
			deploys: []gnoland.TxWithMetadata{
				addPkgFileTx(t, "gno.land/r/demo/x", "x.gno", "file"),
				addPkgFileTx(t, "gno.land/r/demo/x/x.gno", "a.gno", "pkg"),
			},
			files: map[string]string{"r/demo/x/x.gno": "file", "r/demo/x/x.gno:1/a.gno": "pkg"},
		},
		"a package, then a file at its path": {
			deploys: []gnoland.TxWithMetadata{
				addPkgFileTx(t, "gno.land/r/demo/x/x.gno", "a.gno", "pkg"),
				addPkgFileTx(t, "gno.land/r/demo/x", "x.gno", "file"),
			},
			files: map[string]string{"r/demo/x/x.gno/a.gno": "pkg", "r/demo/x:1/x.gno": "file"},
		},
		"a package where another's metadata file goes": {
			deploys: []gnoland.TxWithMetadata{
				addPkgFileTx(t, "gno.land/r/demo/m/"+packageMetadataFile, "a.gno", "pkg"),
				addPkgFileTx(t, "gno.land/r/demo/m", "m.gno", "m"),
			},
			files: map[string]string{"r/demo/m/" + packageMetadataFile + "/a.gno": "pkg", "r/demo/m:1/m.gno": "m"},
		},
		"a moved deploy's path deployed again": {
			deploys: []gnoland.TxWithMetadata{
				addPkgFileTx(t, "gno.land/r/demo/x/license", "a.gno", "pkg"),
				addPkgFileTx(t, "gno.land/r/demo/x", "license", "first"),
				addPkgFileTx(t, "gno.land/r/demo/x", "license", "second"),
			},
			files: map[string]string{
				"r/demo/x/license/a.gno": "pkg",
				"r/demo/x:1/license":     "first",
				"r/demo/x:2/license":     "second",
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			sourceDir, outputDir := t.TempDir(), t.TempDir()
			writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl", tc.deploys...)

			require.NoError(t, execExtract(context.Background(), &extractorCfg{
				fileType:   sourceFileType,
				sourcePath: sourceDir,
				outputDir:  outputDir,
			}))

			for file, body := range tc.files {
				got, err := os.ReadFile(filepath.Join(outputDir, filepath.FromSlash(file)))
				require.NoError(t, err, file)
				assert.Equal(t, body, string(got), file)
			}
		})
	}
}

func TestExtract_SkipsADeployNoNumberCanPlace(t *testing.T) {
	// not parallel: it captures the default logger
	logs := captureLogs(t)

	// a file on the way to the package dir, or a numbered name too long for
	// the filesystem: the deploy is skipped and the run goes on
	long := strings.Repeat("l", maxNameLen-1)
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl",
		addPkgFileTx(t, "gno.land/r/demo/f", "sub", "file"),
		addPkgFileTx(t, "gno.land/r/demo/f/sub/z", "z.gno", "bad"),
		addPkgTx(t, "gno.land/r/demo/"+long, "first"),
		addPkgTx(t, "gno.land/r/demo/"+long, "second"),
		addPkgTx(t, "gno.land/r/demo/x", "x"),
	)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"f", long, "x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, "first", readPkgBody(t, outputDir, "r/demo/"+long))
	assert.Equal(t, 2, strings.Count(logs.String(), "skipping a deploy"))
}

func TestExtract_ReadsOnlyTheSourceDirsOwnFiles(t *testing.T) {
	t.Parallel()

	// a chain dir holds its extracted/ tree: a package file there that looks
	// like a source file must not be read as one
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeSourceFile(t, sourceDir, "backup_0000001-0000010.jsonl", addPkgTx(t, "gno.land/r/demo/x", "x"))
	nested := filepath.Join(sourceDir, "extracted", "r", "demo", "x")
	require.NoError(t, os.MkdirAll(nested, 0o755))
	writeSourceFile(t, nested, "fake.jsonl", addPkgTx(t, "gno.land/r/demo/fake", "fake"))
	require.NoError(t, os.Mkdir(filepath.Join(sourceDir, "old.jsonl"), 0o755))

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
	}))

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
}

func TestExtractAddMessages_DecodesPackageApprovals(t *testing.T) {
	// not parallel: it swaps the default logger
	logs := captureLogs(t)

	// mainnet and onyx park a new package until it is enabled or rejected: those
	// txs (messages as mainnet and onyx store them) carry no package, but must
	// decode rather than be skipped
	enable := `{"@type":"/vm.m_enable_pkg","approver":"g1yaaa6rcp4ew5yjzdj4yms596wx2dtrj3a86704",` +
		`"pkg_path":"gno.land/p/demo/x","pkg_hash":"e3d66ccac3af7c4c5d4f8a87b6755f1119ec75fd5f57040d3dfcd28554e883bd",` +
		`"pkg_height":"9671"}`
	reject := `{"@type":"/vm.m_reject_pkg","sender":"g1ml9grtwnpzqn3hre5ve5vjdlmv2srrmpmc0dsv","pkg_path":"gno.land/r/demo/y"}`
	dir := t.TempDir()
	writeLines(t, dir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", "x")),
		withMsgs(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/z", "z")), enable),
		withMsgs(t, txJSON(t, addPkgTx(t, "gno.land/r/demo/z", "z")), reject),
	)

	msgs, err := extractAddMessages(filepath.Join(dir, "backup_0000001-0000010.jsonl"), decodeTx)
	require.NoError(t, err)

	assert.Len(t, msgs, 1)
	assert.Empty(t, logs.String())
}

func TestExtract_ReadsBlockNumLinesInLegacyMode(t *testing.T) {
	t.Parallel()

	// test2-test4's lines, as tx-archive wrote them before {tx, metadata}: a
	// {tx, blockNum} object, and a deploy's deposit under `deposit`
	deploy := func(body string) string {
		return `{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",` +
			`"deposit":"1ugnot","package":{"name":"x","path":"gno.land/r/demo/x",` +
			`"files":[{"name":"x.gno","body":"` + body + `"}]}}],` +
			`"fee":{"gas_wanted":"1","gas_fee":"1ugnot"},"signatures":null,"memo":""},"blockNum":"64"}`
	}
	call := `{"tx":{"msg":[{"@type":"/vm.m_call","caller":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",` +
		`"send":"","pkg_path":"gno.land/r/demo/x","func":"Do","args":null}],` +
		`"fee":{"gas_wanted":"1","gas_fee":"1ugnot"},"signatures":null,"memo":""},"blockNum":"65"}`
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeLines(t, sourceDir, "backup_0000001-0000100.jsonl", deploy("first"), call, deploy("second"))

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
		legacyMode: true,
	}))

	assert.Equal(t, []string{"x", "x:1"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
	assert.Equal(t, "first", readPkgBody(t, outputDir, "r/demo/x"))
	assert.Equal(t, "second", readPkgBody(t, outputDir, "r/demo/x:1"))
	metadata, err := os.ReadFile(filepath.Join(outputDir, "r", "demo", "x", packageMetadataFile))
	require.NoError(t, err)
	assert.JSONEq(t, `{"creator":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5","deposit":"1ugnot"}`, string(metadata))
}

func TestExtract_ReadsCapitalizedKeysInLegacyMode(t *testing.T) {
	t.Parallel()

	// test1's plain std.Tx lines; test1-test3 predate snake_case package keys
	line := `{"msg":[{"@type":"/vm.m_addpkg","creator":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",` +
		`"deposit":"100gnot","package":{"Name":"avl","Path":"gno.land/p/avl",` +
		`"Files":[{"Name":"avl.gno","Body":"tree"}]}}],` +
		`"fee":{"gas_wanted":"1","gas_fee":"1gnot"},"signatures":null,"memo":""}`
	sourceDir, outputDir := t.TempDir(), t.TempDir()
	writeLines(t, sourceDir, "txexport-aa.log", line)

	require.NoError(t, execExtract(context.Background(), &extractorCfg{
		fileType:   ".log",
		sourcePath: sourceDir,
		outputDir:  outputDir,
		legacyMode: true,
	}))

	body, err := os.ReadFile(filepath.Join(outputDir, "p", "avl", "avl.gno"))
	require.NoError(t, err)
	assert.Equal(t, "tree", string(body))
	metadata, err := os.ReadFile(filepath.Join(outputDir, "p", "avl", packageMetadataFile))
	require.NoError(t, err)
	assert.JSONEq(t, `{"creator":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5","deposit":"100gnot"}`, string(metadata))
}

func TestExtract_FailsOnADeployItCannotParseInLegacyMode(t *testing.T) {
	t.Parallel()

	line := `{"tx":{"msg":[{"@type":"/vm.m_addpkg","creator":"not-an-address","deposit":"",` +
		`"package":{"name":"x","path":"gno.land/r/demo/x","files":[]}}],"fee":{},"signatures":null,"memo":""},` +
		`"blockNum":"1"}`
	sourceDir := t.TempDir()
	writeLines(t, sourceDir, "backup_0000001-0000100.jsonl", line)

	err := execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  filepath.Join(t.TempDir(), "extracted.new"),
		legacyMode: true,
	})

	assert.ErrorIs(t, err, errUnparsableDeploy)
}

func TestExtractAddMessages_CountsALongLineOnce(t *testing.T) {
	// not parallel: it captures the default logger
	logs := captureLogs(t)

	dir := t.TempDir()
	writeLines(t, dir, "backup_0000001-0000010.jsonl",
		txJSON(t, addPkgTx(t, "gno.land/r/demo/x", strings.Repeat("x", 10000))),
		"not json",
	)

	_, err := extractAddMessages(filepath.Join(dir, "backup_0000001-0000010.jsonl"), decodeTx)
	require.NoError(t, err)

	assert.Contains(t, logs.String(), "line=2")
}

// legacyExtract runs a legacy-mode extraction of lines into a fresh output dir.
func legacyExtract(t *testing.T, lines ...string) (string, error) {
	t.Helper()

	sourceDir, outputDir := t.TempDir(), filepath.Join(t.TempDir(), "extracted.new")
	writeLines(t, sourceDir, "backup_0000001-0000100.jsonl", lines...)
	return outputDir, execExtract(context.Background(), &extractorCfg{
		fileType:   sourceFileType,
		sourcePath: sourceDir,
		outputDir:  outputDir,
		legacyMode: true,
	})
}

// blockNumLine is a {tx, blockNum} line holding msgs, as in test2-test4.
func blockNumLine(msgs string) string {
	return `{"tx":{"msg":[` + msgs + `],"fee":{"gas_wanted":"1","gas_fee":"1ugnot"},"signatures":null,"memo":""},"blockNum":"1"}`
}

const (
	legacyCreator = `"creator":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"`
	legacyPackage = `"package":{"name":"x","path":"gno.land/r/demo/x","files":[{"name":"x.gno","body":"x"}]}`
)

func TestExtract_ReadsADeployNextToOtherMsgsInLegacyMode(t *testing.T) {
	t.Parallel()

	outputDir, err := legacyExtract(t, blockNumLine(
		`{"@type":"/vm.m_call","caller":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5","pkg_path":"gno.land/r/demo/x","func":"Do"},`+
			`{"@type":"/vm.m_addpkg",`+legacyCreator+`,"deposit":"",`+legacyPackage+`}`))
	require.NoError(t, err)

	assert.Equal(t, "x", readPkgBody(t, outputDir, "r/demo/x"))
}

func TestExtract_PrefersTxOverTopLevelMsgsInLegacyMode(t *testing.T) {
	t.Parallel()

	// a {tx, blockNum} line's msgs are under tx: top-level msgs are not the tx's
	outputDir, err := legacyExtract(t, `{"msg":[{"@type":"/vm.m_addpkg",`+legacyCreator+`,"deposit":"",`+
		`"package":{"name":"z","path":"gno.land/r/demo/z","files":[{"name":"x.gno","body":"z"}]}}],`+
		`"tx":{"msg":[{"@type":"/vm.m_addpkg",`+legacyCreator+`,"deposit":"",`+legacyPackage+`}]},"blockNum":"1"}`)
	require.NoError(t, err)

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
}

func TestExtract_SkipsANullFileInLegacyMode(t *testing.T) {
	t.Parallel()

	outputDir, err := legacyExtract(t,
		blockNumLine(`{"@type":"/vm.m_addpkg",`+legacyCreator+`,"deposit":"",`+
			`"package":{"name":"y","path":"gno.land/r/demo/y","files":[null]}}`),
		blockNumLine(`{"@type":"/vm.m_addpkg",`+legacyCreator+`,"deposit":"",`+legacyPackage+`}`),
	)
	require.NoError(t, err)

	assert.Equal(t, []string{"x"}, dirNames(t, filepath.Join(outputDir, "r", "demo")))
}

func TestExtract_FailsOnAMalformedDeployInLegacyMode(t *testing.T) {
	t.Parallel()

	for name, msgs := range map[string]string{
		"null package":    `{"@type":"/vm.m_addpkg",` + legacyCreator + `,"deposit":"","package":null}`,
		"invalid deposit": `{"@type":"/vm.m_addpkg",` + legacyCreator + `,"deposit":"1UGNOT",` + legacyPackage + `}`,
		"non-object msg":  `1,{"@type":"/vm.m_addpkg",` + legacyCreator + `,"deposit":"",` + legacyPackage + `}`,
		// a key these formats never carry: decoding it as one of theirs would
		// misread it (here, a deposit under today's `send`)
		"unknown key": `{"@type":"/vm.m_addpkg",` + legacyCreator + `,"send":"1ugnot",` + legacyPackage + `}`,
		"unknown package key": `{"@type":"/vm.m_addpkg",` + legacyCreator + `,"deposit":"",` +
			`"package":{"name":"x","path":"gno.land/r/demo/x","type":"","files":[{"name":"x.gno","body":"x"}]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			_, err := legacyExtract(t, blockNumLine(msgs))
			assert.ErrorIs(t, err, errUnparsableDeploy)
		})
	}
}

func TestSortByBlockRange(t *testing.T) {
	t.Parallel()

	paths := []string{
		"txexport-ab.log",
		"backup_staging_txs_10001-11000.jsonl",
		"backup_staging_balances.jsonl",
		"backup_50-60.jsonl",
		"other_1001-1500.jsonl",
		"backup_1-100.jsonl",
		"txexport-aa.log",
		"backup_staging_txs_1001-2000.jsonl",
	}

	sortByBlockRange(paths)

	assert.Equal(t, []string{
		// by the first number of the range, not the last
		"backup_1-100.jsonl",
		"backup_50-60.jsonl",
		// same first number: lexical order
		"backup_staging_txs_1001-2000.jsonl",
		"other_1001-1500.jsonl",
		"backup_staging_txs_10001-11000.jsonl",
		// names without a range last, in lexical order
		"backup_staging_balances.jsonl",
		"txexport-aa.log",
		"txexport-ab.log",
	}, paths)
}

// Helpers
func addPkgTx(t *testing.T, path, body string) gnoland.TxWithMetadata {
	t.Helper()

	return gnoland.TxWithMetadata{Tx: std.Tx{Msgs: []std.Msg{vm.MsgAddPackage{
		Creator: addressFromString(t, "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"),
		Package: &std.MemPackage{
			Name:  "x",
			Path:  path,
			Files: []*std.MemFile{{Name: "x.gno", Body: body}},
		},
	}}}}
}

// addPkgFileTx is a deploy of path with one file, name, holding body.
func addPkgFileTx(t *testing.T, path, name, body string) gnoland.TxWithMetadata {
	t.Helper()

	tx := addPkgTx(t, path, body)
	tx.Tx.Msgs[0].(vm.MsgAddPackage).Package.Files[0].Name = name
	return tx
}

func writeSourceFile(t *testing.T, dir, name string, txs ...gnoland.TxWithMetadata) {
	t.Helper()

	file, err := os.Create(filepath.Join(dir, name))
	require.NoError(t, err)
	for _, tx := range txs {
		require.NoError(t, writeTxToFile(t, tx, file))
	}
	require.NoError(t, file.Close())
}

// txJSON is the amino JSON line of tx, as the backups store it.
func txJSON(t *testing.T, tx gnoland.TxWithMetadata) string {
	t.Helper()

	data, err := amino.MarshalJSON(tx)
	require.NoError(t, err)
	return string(data)
}

// withMsgs replaces the msg list of the tx line with msgs (JSON objects).
func withMsgs(t *testing.T, line string, msgs string) string {
	t.Helper()

	start, end := strings.Index(line, `"msg":[`), strings.Index(line, `],"fee"`)
	require.True(t, start >= 0 && end > start, "a tx line: %s", line)
	return line[:start] + `"msg":[` + msgs + line[end:]
}

// mustReplace replaces the first old in s with new; old must occur in s.
func mustReplace(t *testing.T, s, old, new string) string {
	t.Helper()

	require.Contains(t, s, old)
	return strings.Replace(s, old, new, 1)
}

func writeLines(t *testing.T, dir, name string, lines ...string) {
	t.Helper()

	data := strings.Join(lines, "\n") + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644))
}

// captureLogs sends the default logger's output to the returned buffer until
// the test ends. slog.SetDefault also redirects the log package, which
// restoring the previous default does not undo, so that is restored too.
// Tests calling it must not run in parallel.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()

	logs := new(bytes.Buffer)
	previous, writer, flags := slog.Default(), log.Writer(), log.Flags()
	t.Cleanup(func() {
		slog.SetDefault(previous)
		log.SetOutput(writer)
		log.SetFlags(flags)
	})
	slog.SetDefault(slog.New(slog.NewTextHandler(logs, nil)))
	return logs
}

// openFiles counts the process's open file descriptors. It lists names only:
// stating them would fail on the descriptor of the listing itself.
func openFiles(t *testing.T) int {
	t.Helper()

	dir, err := os.Open("/dev/fd")
	require.NoError(t, err)
	defer dir.Close()
	names, err := dir.Readdirnames(-1)
	require.NoError(t, err)
	return len(names)
}

func readPkgBody(t *testing.T, outputDir, pkgDir string) string {
	t.Helper()

	body, err := os.ReadFile(filepath.Join(outputDir, filepath.FromSlash(pkgDir), "x.gno"))
	require.NoError(t, err)
	return string(body)
}

func dirNames(t *testing.T, dir string) []string {
	t.Helper()

	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func generateSourceFiles(t *testing.T, dir string, mockMsgs []std.Msg, numSourceFiles int) []string {
	t.Helper()

	var (
		txPerSourceFile = 5
		mockTx          = make([]gnoland.TxWithMetadata, txPerSourceFile*numSourceFiles)
		testFiles       = make([]string, numSourceFiles)
		msgPerTx        = len(mockMsgs) / len(mockTx)
	)

	// Generate transactions to wrap messages
	for i := range mockTx {
		mockTx[i] = gnoland.TxWithMetadata{
			Tx: std.Tx{
				Msgs: mockMsgs[:msgPerTx],
			},
		}
		mockMsgs = mockMsgs[msgPerTx:]
	}

	// Generate source file names
	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = "sourceFile" + strconv.Itoa(i) + sourceFileType
	}

	// Generate source files
	for _, file := range testFiles {
		filePath := filepath.Join(dir, file)

		err := os.MkdirAll(filepath.Dir(filePath), os.ModePerm)
		require.NoError(t, err)

		file, err := os.Create(filePath)
		require.NoError(t, err)

		for _, tx := range mockTx[:txPerSourceFile] {
			err := writeTxToFile(t, tx, file)
			if err != nil {
				t.Fatal(err)
			}
		}
		mockTx = mockTx[txPerSourceFile:]
	}

	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = filepath.Join(dir, testFiles[i])
	}

	return testFiles
}

func generateMockMsgs(t *testing.T) ([]std.Msg, []vm.MsgAddPackage) {
	t.Helper()

	r := rand.New(rand.NewSource(time.Now().UnixNano()))

	testAddresses := []string{
		"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
		"g1f4v282mwyhu29afke4vq5r2xzcm6z3ftnugcnv",
		"g127jydsh6cms3lrtdenydxsckh23a8d6emqcvfa",
		"g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq",
		"g1rrf8s5mrmu00sx04fzfsvc399fklpeg2x0a7mz",
	}

	var ret []std.Msg
	var addPkgRet []vm.MsgAddPackage
	numMsg := 100

	pkgID := 0

	for i := 0; i < numMsg; i++ {
		var (
			randNum           = int(r.Uint32())
			msg               std.Msg
			randAddressIndex  = randNum % len(testAddresses)
			maxDepositAmount  = 5000
			callerAddr        = addressFromString(t, testAddresses[randAddressIndex])
			deposit           = std.NewCoins(std.NewCoin("foo", int64(randNum%maxDepositAmount+1)))
			path              = "gno.land/"
			pkgName           = "package" + strconv.Itoa(pkgID)
			maxArgs           = 2
			maxFileBodyLength = 200
			maxFilesPerPkg    = 100
		)

		if randNum%2 == 0 {
			path += "r/"
		} else {
			path += "p/"
		}

		switch randNum % 3 {
		case 0: // Making vm.MsgAddPackage msg
			var files []*std.MemFile

			path += pkgName

			for j := 0; j < randNum%maxFilesPerPkg+1; j++ {
				file := &std.MemFile{
					Name: "t" + strconv.Itoa(j) + ".gno",
					Body: randString(t, int(r.Uint32())%maxFileBodyLength+1),
				}
				files = append(files, file)
			}

			msg = vm.MsgAddPackage{
				Creator: callerAddr,
				Package: &std.MemPackage{
					Name:  pkgName,
					Path:  path,
					Files: files,
				},
				Send: deposit,
			}
			addPkgRet = append(addPkgRet, msg.(vm.MsgAddPackage))
			break
		case 1: // Making vm.MsgCall msg
			args := make([]string, maxArgs-randNum%2)
			for i := range args {
				args[i] = randString(t, 10)
			}

			msg = vm.MsgCall{
				Caller:  callerAddr,
				Send:    deposit,
				PkgPath: path + pkgName,
				Func:    "Func" + strconv.Itoa(i),
				Args:    args,
			}
			break
		case 2: // Making bank.MsgSend
			// Remove already used address
			ta := append(testAddresses[:randAddressIndex], testAddresses[randAddressIndex+1:]...)

			msg = bank.MsgSend{
				FromAddress: callerAddr,
				ToAddress:   addressFromString(t, ta[randNum%len(ta)]),
				Amount:      deposit,
			}
		}
		ret = append(ret, msg)
		pkgID++
	}

	return ret, addPkgRet
}

func addressFromString(t *testing.T, addr string) crypto.Address {
	t.Helper()

	ret, err := crypto.AddressFromString(addr)
	require.NoError(t, err)

	return ret
}

func randString(t *testing.T, length int) string {
	t.Helper()
	buf := make([]byte, length)
	_, _ = crand.Read(buf)
	return base64.StdEncoding.EncodeToString(buf)
}

func writeTxToFile(t *testing.T, tx gnoland.TxWithMetadata, file *os.File) error {
	t.Helper()

	data, err := amino.MarshalJSON(tx)
	require.NoError(t, err)

	// Write the JSON data as a line to the file
	_, err = file.Write(data)
	require.NoError(t, err)

	// Write a newline character to separate JSON objects
	_, err = file.Write([]byte("\n"))
	require.NoError(t, err)

	return nil
}

func removeDir(t *testing.T, dirPath string) func() {
	return func() {
		err := os.RemoveAll(dirPath)
		require.NoError(t, err)
	}
}
