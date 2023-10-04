package extractor

import (
	"bufio"
	"encoding/json"
	"fmt"
	"github.com/joho/godotenv"
	"log"
	"os"
	"strings"
	"sync"
)

func processFile(fileName string, wg *sync.WaitGroup) {
	defer wg.Done()

	file, err := os.Open(fileName)

	if err != nil {
		fmt.Print("Error opening file: ", err)
		return
	}

	defer func(file *os.File) {
		err := file.Close()
		if err != nil {
			log.Fatalf("Could not close file %s properly.", file.Name())
		}
	}(file)

	pkgMap := make(map[string]TX) // path -> package

	scanner := bufio.NewScanner(file)
	for i := 0; scanner.Scan(); i++ {
		var tx TX

		line := scanner.Text()

		if err := json.Unmarshal([]byte(line), &tx); err != nil {
			fmt.Printf("Error parsing JSON at line %d: %v\n", i, err)
			continue
		}

		if tx.Msg[0].Type == "/vm.m_addpkg" {
			path := tx.Msg[0].Package.Path

			// do not add duplicates
			_, ok := pkgMap[path]
			if !ok {
				writePkg(tx)
				pkgMap[path] = tx
			}
		}
	}
}

func writePkg(tx TX) {
	msg := tx.Msg[0]
	trimmedPath := strings.TrimLeft(msg.Package.Path, "gno.land/")

	// write dirs needed to write package
	writePath := extractionDir + trimmedPath + "/"
	if err := os.MkdirAll(writePath, os.ModePerm); err != nil {
		log.Fatal(err)
	}

	metadata, err := tx.MarshalMetadata()

	if err != nil {
		log.Fatal("Failed to marshal metadata: " + trimmedPath)
	}

	// write metadata
	err = os.WriteFile(writePath+"pkg_metadata.json", metadata, 0644)
	if err != nil {
		log.Fatal(err)
	}

	// write files
	for _, file := range msg.Package.Files {
		err := os.WriteFile(writePath+file.Name, []byte(file.Body), 0644)
		if err != nil {
			log.Fatal(err)
		}
	}
}

var (
	// dirs have trailing slashes
	logDir        string
	extractionDir string
)

func main() {
	// load env
	err := godotenv.Load()
	if err != nil {
		log.Fatal("Error loading .env file")
	}
	logDir = os.Getenv("LOGS_DIR")
	extractionDir = os.Getenv("EXTRACTION_DIR")

	// read log files
	entries, err := os.ReadDir(logDir)
	if err != nil {
		log.Fatal(err)
	}

	// goroutine for each log file
	var wg sync.WaitGroup
	for _, e := range entries {
		wg.Add(1)
		go processFile(logDir+e.Name(), &wg)
	}
	wg.Wait()
}
