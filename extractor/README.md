# Gno Source Code Extractor

This tool is a simple parser to extract source code (packages & realms) from logs created by the [tx-archive](https://github.com/gnolang/gno/tree/master/contribs/tx-archive) tool for Gno chains.

**Note:** outside `-legacy-mode`, this tool parses transaction data using the
gno data types from the version of [gnolang/gno](https://github.com/gnolang/gno)
pinned in [`go.mod`](./go.mod); it is compatible with whatever that version
supports. Bump that dependency to stay compatible with newer chain data: it
must know every message type mainnet and onyx emit, or their txs are skipped,
and a deploy it cannot decode fails the run.

## Running the extractor

```
USAGE
  [flags]

The Gno / TM2 source code extractor service

FLAGS
  -file-type .jsonl        the file type for analysis, with a preceding period (ie .jsonl)
  -legacy-mode=false       read the formats older than {tx, metadata} lines: plain std.Tx (test1) or {tx, blockNum} (test2-test4)
  -output-dir ./extracted  the output directory for the extracted Gno source code
  -source-path string      the source file or folder containing transaction data
```

A `-source-path` dir is read for the files of `-file-type` directly in it, not
in its subdirs, which in a chain dir hold the `extracted/` tree.

`-output-dir` must be absent or empty: the extractor never writes into an
earlier tree. In a chain dir, `make extractor` builds a fresh tree and swaps it
in for `extracted/` only when the run succeeds and writes at least one package;
otherwise it fails and keeps `extracted/`.

`-legacy-mode` reads the backups that predate tx-archive's `{tx, metadata}`
lines: test1's plain `std.Tx` lines, and test2-test4's `{tx, blockNum}` ones. It
decodes their deploys without the gno types, which reject those formats' fields
(a deploy's `deposit`) and test1-test3's capitalized package keys, and fails on a
key those formats never carry. A chain dir passes it to `make extractor` with
`EXTRACTOR_FLAGS`: test4 sets `-legacy-mode`, and test1, whose backups are
`txexport-*.log`, sets `-legacy-mode -file-type .log`.

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

Paths and file names come from the chain, rejected txs included, so a deploy
never fails the run over them:

- A package is skipped, with a warning, when its path or a file name would
  leave its dir (`..`, an absolute path, `.`), or holds a NUL or a `:` (that
  of the numbered dirs), or is longer than the filesystem takes, or when a
  file is named `pkg_metadata.json`.
- A deploy whose dir an earlier one blocked (a file where it needs a dir, as
  with a package `r/x` holding a file `license` and a package `r/x/license`)
  moves to its path's next free number, with a warning. It is skipped when no
  number helps: a file on the way to its dir, or a numbered name too long.

test2 and test3 keep an older layout: deploys in `<path>:<block height>`, the
first one also in `<path>`. Their trees hold every deploy of their backups, so
they are not rebuilt: their Makefiles do not set `EXTRACTOR_FLAGS`, so `make
extractor` there fails at the first deploy and keeps the tree. Passing
`EXTRACTOR_FLAGS=-legacy-mode` would rebuild them in the numbered layout,
dropping the block heights.
