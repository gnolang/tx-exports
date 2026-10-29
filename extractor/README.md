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

The Gno / TM2 source code extractor service

FLAGS
  -file-type .jsonl        the file type for analysis, with a preceding period (ie .jsonl)
  -legacy-mode=false       flag indicating if the legacy tx sheet mode should be used
  -output-dir ./extracted  the output directory for the extracted Gno source code
  -source-path string      the source file or folder containing transaction data
```

`-output-dir` must be absent or empty: the extractor never writes into an
earlier tree. In a chain dir, `make extractor` builds a fresh tree and swaps it
in for `extracted/` only when the run succeeds and writes at least one package;
otherwise it fails and keeps `extracted/`.

A `/vm.m_addpkg` tx the extractor cannot parse fails the run, since skipping it
would drop its package from a rebuilt tree. Other lines it cannot parse, such
as message types newer than its gno dependency, are logged and skipped.

## Output layout

Each `/vm.m_addpkg` message is extracted to `<output-dir>/<path without
gno.land/>`, with its files and a `pkg_metadata.json` (creator and deposit).

A path deployed more than once keeps every deploy, numbered in chain order:
the first in `<path>`, the next ones in `<path>:1`, `<path>:2`, and so on.
Source files are read by the range in their names (`…_<from>-<to>.jsonl`:
blocks, or lines for staging's chunks), so the numbering follows the chain
even where names are not zero-padded. The source files carry no tx results, so
any deploy of a path, the first included, may be one the chain rejected.

test2, test3 and test4 keep an older layout: deploys in `<path>:<block height>`,
the first one also in `<path>`. This extractor cannot parse their backups, so
their trees are not rebuilt.
