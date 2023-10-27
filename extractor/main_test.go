package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"github.com/gnolang/gno/gno.land/pkg/sdk/vm"
	"github.com/gnolang/gno/tm2/pkg/amino"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/sdk/bank"
	"github.com/gnolang/gno/tm2/pkg/std"
	"github.com/go-test/deep"
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
	numSourceFiles    = 20
	numTx             = 100
	numMsg            = 200
	maxFilesPerPkg    = 100
	maxFileBodyLength = 200
	msgPerTx          = numMsg / numTx
	txPerSourceFile   = numTx / numSourceFiles
	maxDepositAmount  = 5000
	maxArgs           = 2
	sourceFileType    = ".log"
)

var (
	chars = []rune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890\\n\\t!@#$%^&*()_+><?|:{}~")
)

// Tests
func TestFindFilePaths(t *testing.T) {
	t.Parallel()

	tempDir, err := os.MkdirTemp(".", "test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	testFiles := make([]string, numSourceFiles)

	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = "sourceFile" + strconv.Itoa(i) + sourceFileType
	}

	for _, file := range testFiles {
		filePath := filepath.Join(tempDir, file)
		if err := os.MkdirAll(filepath.Dir(filePath), os.ModePerm); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Create(filePath); err != nil {
			t.Fatal(err)
		}
	}

	results, err := findFilePaths(tempDir, ".log")
	if err != nil {
		t.Fatal(err)
	}

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

	if len(results) != len(expectedResults) {
		t.Fatalf("Expected %d results, but got %d", len(expectedResults), len(results))
	}

	for i, result := range results {
		if result != expectedResults[i] {
			t.Errorf("Expected %s, but got %s", expectedResults[i], result)
		}
	}
}

func TestProcessSourceFiles(t *testing.T) {
	t.Parallel()

	mockMsgs, mockMsgsAddPackage := generateMockMsgs(t)
	sourceFiles := generateSourceFiles(t, mockMsgs)

	var results []vm.MsgAddPackage
	for _, sf := range sourceFiles {
		res, err := processSourceFile(sf)
		if err != nil {
			t.Fatal(err)
		}
		results = append(results, res...)
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].Package.Name < results[j].Package.Name
	})
	sort.Slice(mockMsgsAddPackage, func(i, j int) bool {
		return mockMsgsAddPackage[i].Package.Name < mockMsgsAddPackage[j].Package.Name
	})

	if diff := deep.Equal(results, mockMsgsAddPackage); diff != nil {
		fmt.Println(diff)
	}
}

func TestWritePackageMetadata(t *testing.T) {
	t.Parallel()

	_, mockMsgsAddPackage := generateMockMsgs(t)

	// Make temp dir
	tempDir, err := os.MkdirTemp(".", "test")
	if err != nil {
		t.Fatal(err)
	}

	for _, msg := range mockMsgsAddPackage {
		md := metadataFromMsg(msg)

		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

		// Write dir before writing metadata
		if dirWriteErr := os.MkdirAll(outputDir, os.ModePerm); dirWriteErr != nil {
			t.Fatal(dirWriteErr)
		}

		// Write the metadata
		err := writePackageMetadata(md, outputDir)
		require.NoError(t, err)

		// Read file
		file, err := os.Open(filepath.Join(outputDir, packageMetadataFile))
		require.NoError(t, err)

		reader := bufio.NewReader(file)
		var unmarshalledMetadata Metadata

		raw, isPrefix, err := reader.ReadLine()
		require.NoError(t, err)

		if isPrefix {
			t.Fatalf("Metadata longer then buffer max size at %s\n", outputDir)
		}

		err = json.Unmarshal(raw, &unmarshalledMetadata)
		require.NoError(t, err)

		t.Cleanup(func() {
			err := os.RemoveAll(tempDir)
			if err != nil {
				fmt.Printf("could not clean up temp dir, %v", err)
				return
			}
		})

		require.Equal(t, md, unmarshalledMetadata)
	}
}

func TestWritePackageFiles(t *testing.T) {
	t.Parallel()

	_, mockMsgsAddPackage := generateMockMsgs(t)

	tempDir, err := os.MkdirTemp(".", "test")
	if err != nil {
		t.Fatal(err)
	}

	for _, msg := range mockMsgsAddPackage {
		// Get output dir
		outputDir := filepath.Join(tempDir, strings.TrimLeft(msg.Package.Path, "gno.land/"))

		// Write dir before writing metadata
		if dirWriteErr := os.MkdirAll(outputDir, os.ModePerm); dirWriteErr != nil {
			t.Fatal(dirWriteErr)
		}

		// Write the metadata
		err := writePackageFiles(msg, outputDir)
		require.NoError(t, err)

		// Read & compare file
		for _, f := range msg.Package.Files {
			contents, err := os.ReadFile(filepath.Join(outputDir, f.Name))
			require.NoError(t, err)
			require.Equal(t, f.Body, string(contents))
		}
	}
	t.Cleanup(func() {
		err := os.RemoveAll(tempDir)
		if err != nil {
			fmt.Printf("could not clean up temp dir, %v", err)
			return
		}
	})
}

// Helpers
func generateSourceFiles(t *testing.T, mockMsgs []std.Msg) []string {
	t.Helper()

	tempDir, err := os.MkdirTemp(".", "test")
	if err != nil {
		t.Fatal(err)
	}

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
		if err := os.MkdirAll(filepath.Dir(filePath), os.ModePerm); err != nil {
			t.Fatal(err)
		}
		file, err := os.Create(filePath)

		if err != nil {
			t.Fatal(err)
		}

		for _, tx := range mockTx[:txPerSourceFile] {

			err := writeTxToFile(tx, file, t)
			if err != nil {
				t.Fatal(err)
			}
		}
		mockTx = mockTx[txPerSourceFile:]
	}

	for i := 0; i < numSourceFiles; i++ {
		testFiles[i] = filepath.Join(tempDir, testFiles[i])
	}

	t.Cleanup(func() {
		err := os.RemoveAll(tempDir)
		if err != nil {
			fmt.Printf("could not clean up temp dir, %v", err)
			return
		}
	})

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
			randNum          = int(r.Uint32())
			msg              std.Msg
			randAddressIndex = randNum % len(testAddresses)
			callerAddr       = addressFromString(testAddresses[randAddressIndex], t)
			deposit          = std.NewCoins(std.NewCoin("foo", int64(randNum%maxDepositAmount+1)))
			path             = "gno.land/"
			pkgName          = "package" + strconv.Itoa(pkgID)
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
					Body: randString(int(r.Uint32()) % maxFileBodyLength),
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
				args[i] = randString(10)
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
	if err != nil {
		t.Errorf("cannot convert string to address, %v", err)
	}
	return ret
}

func randString(length int) string {
	b := make([]rune, length)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

func writeTxToFile(tx std.Tx, file *os.File, t *testing.T) error {
	data, err := amino.MarshalJSON(tx)
	if err != nil {
		t.Errorf("unable to marshal JSON data, %v", err)
	}

	// Write the JSON data as a line to the file
	_, err = file.Write(data)
	if err != nil {
		t.Errorf("unable to write to output, %v", err)
	}

	// Write a newline character to separate JSON objects
	_, err = file.Write([]byte("\n"))
	if err != nil {
		t.Errorf("unable to write newline output, %v", err)
	}

	return nil
}
