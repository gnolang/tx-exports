# Gno Source Code Extractor

This tool is a simple parser to extract source code (packages & realms) from logs created by the [tx-archive](https://github.com/gnolang/gno/tree/master/contribs/tx-archive) tool for Gno chains.

**Note:** this tool parses transaction data using the gno data types from the
version of [gnolang/gno](https://github.com/gnolang/gno) pinned in
[`go.mod`](./go.mod); it is compatible with whatever that version supports.
Bump that dependency to stay compatible with newer chain data.

## Running the extractor

The extractor takes in three arguments:
- the filetype of the archive files,
- output directory for the extracted packages,
- the root directory where the archive files are located.

```
USAGE
  [flags]

The Gno source code extractor service

FLAGS
  -file-type  .jsonl       the file type for analysis, with a preceding period (ie .log)
  -output-dir ./extracted  the output directory for the extracted Gno source code
  -source-dir .            the root folder containing transaction data
```

