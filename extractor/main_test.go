package main

import (
	"bufio"
	crand "crypto/rand"
	"encoding/base64"
	"encoding/json"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/stretchr/testify/require"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

const (
	numSourceFiles  = 20
	numTx           = 100
	numMsg          = 200
	msgPerTx        = numMsg / numTx
	txPerSourceFile = numTx / numSourceFiles
	sourceFileType  = ".log"
)

// Tests
func TestFindFilePaths(t *testing.T) {
	t.Parallel()

	tempDir, err := os.MkdirTemp(".", "test")
	t.Cleanup(removeDir(t, tempDir))
	require.NoError(t, err)

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

	results, err := findFilePaths(tempDir, ".log")
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

	mockMsgs, mockMsgsAddPackage := generateMockMsgs(t)
	sourceFiles := generateSourceFiles(t, mockMsgs)

	var results []vm.MsgAddPackage
	for _, sf := range sourceFiles {
		res, err := extractAddMessages(sf)
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
	t.Cleanup(removeDir(t, tempDir))
	require.NoError(t, err)

	for _, msg := range mockMsgsAddPackage {
		md := metadataFromMsg(msg)

		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

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
	t.Cleanup(removeDir(t, tempDir))
	require.NoError(t, err)

	for _, msg := range mockMsgsAddPackage {
		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

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

// Helpers
func generateSourceFiles(t *testing.T, mockMsgs []std.Msg) []string {
	t.Helper()

	tempDir, err := os.MkdirTemp(".", "test")
	t.Cleanup(removeDir(t, tempDir))
	require.NoError(t, err)

	var (
		mockTx    = make([]std.Tx, numTx)
		testFiles = make([]string, numSourceFiles)
	)

	// Generate transactions to wrap messages
	for i := range mockTx { // num
		mockTx[i] = std.Tx{
			Msgs: mockMsgs[:msgPerTx],
		}
		mockMsgs = mockMsgs[msgPerTx:]
	}

	// Generate source file names
	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = "sourceFile" + strconv.Itoa(i) + sourceFileType
	}

	// Generate source files
	for _, file := range testFiles {
		filePath := filepath.Join(tempDir, file)

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
		testFiles[i] = filepath.Join(tempDir, testFiles[i])
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

	pkgID := 0

	for i := 0; i < numMsg; i++ {
		var (
			randNum           = int(r.Uint32())
			msg               std.Msg
			randAddressIndex  = randNum % len(testAddresses)
			maxDepositAmount  = 5000
			callerAddr        = addressFromString(testAddresses[randAddressIndex], t)
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
					Body: randString(t, int(r.Uint32())%maxFileBodyLength),
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
				Deposit: deposit,
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
				ToAddress:   addressFromString(ta[randNum%len(ta)], t),
				Amount:      deposit,
			}
		}
		ret = append(ret, msg)
		pkgID++
	}

	return ret, addPkgRet
}

func addressFromString(addr string, t *testing.T) crypto.Address {
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

func writeTxToFile(t *testing.T, tx std.Tx, file *os.File) error {
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
