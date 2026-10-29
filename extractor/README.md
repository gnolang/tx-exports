# Gno Source Code Extractor

This tool is a simple parser to extract source code (packages & realms) from logs created by the [tx-archive](https://github.com/gnolang/gno/tree/master/contribs/tx-archive) tool for Gno chains.

**Note:** this tool parses transaction data using the gno data types from the
version of [gnolang/gno](https://github.com/gnolang/gno) pinned in
[`go.mod`](./go.mod); it is compatible with whatever that version supports.
Bump that dependency to stay compatible with newer chain data.

## Running the extractor

```
USAGE
  [flags]

The Gno source code extractor service

FLAGS
  -file-type .jsonl        the file type for analysis, with a preceding period (ie .jsonl)
  -legacy-mode=false       flag indicating if the legacy tx sheet mode should be used
  -output-dir ./extracted  the output directory for the extracted Gno source code
  -source-path string      the source file or folder containing transaction data
```

`-output-dir` must be absent or empty: the extractor never writes into an
earlier tree. In a chain dir, `make extractor` builds a fresh tree and swaps it
in for `extracted/` once the run succeeds.

## Output layout

Each `/vm.m_addpkg` message is extracted to `<output-dir>/<path without
gno.land/>`, with its files and a `pkg_metadata.json` (creator and deposit).

A path deployed more than once keeps every deploy, numbered in chain order:
the first in `<path>`, the next ones in `<path>:1`, `<path>:2`, and so on.
Source files are read by the block range in their names (`…_<from>-<to>.jsonl`),
so the numbering follows the chain even where names are not zero-padded. The
source files carry no tx results, so a numbered deploy may be one the chain
rejected.
