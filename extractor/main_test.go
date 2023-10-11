package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindFilePaths(t *testing.T) {

	tempDir, err := os.MkdirTemp(".", "test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	testFiles := []string{
		"file1.txt",
		"file2.log",
		"file3.log",
		"file4.log",
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

	expectedResults := []string{
		filepath.Join(tempDir, "file2.log"),
		filepath.Join(tempDir, "file3.log"),
		filepath.Join(tempDir, "file4.log"),
	}

	if len(results) != len(expectedResults) {
		t.Fatalf("Expected %d results, but got %d", len(expectedResults), len(results))
	}

	for i, result := range results {
		if result != expectedResults[i] {
			t.Errorf("Expected %s, but got %s", expectedResults[i], result)
		}
	}

}
