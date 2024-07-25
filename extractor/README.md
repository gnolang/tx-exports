# Gno Source Code Extractor

This tool is a simple parser to extract source code (packages & realms) from logs created by the [tx-archive](https://github.com/gnolang/tx-archive) tool for Gno chains.

**Note:** as of test4, this extractor is no longer working as it parses
`MsgAddPackage` incorrectly. `extractor-0.1.1` should be used instead.

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

