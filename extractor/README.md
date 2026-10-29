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
key those formats' deploy messages never carry. A line's other keys, and its
other message types, are ignored. A chain dir passes it to `make extractor` with
`EXTRACTOR_FLAGS`: test4 sets `-legacy-mode`, and test1, whose backups are
`txexport-*.log`, sets `-legacy-mode -file-type .log`.

A `/vm.m_addpkg` tx the extractor cannot parse fails the run, since skipping it
would drop its package from a rebuilt tree. Other lines it cannot parse, such
as message types newer than its gno dependency, are logged and skipped.

## Output layout

Each `/vm.m_addpkg` message is extracted to `<output-dir>/<path without
gno.land/>`, with its files and a `pkg_metadata.json` (creator and deposit).

A path deployed more than once keeps every deploy, numbered in chain order:
the first in `<path>` (or `<path>:1` when it moves, see below), the next ones
in `<path>:1`, `<path>:2`, and so on. Source files are read by the range in
their names (`…_<from>-<to>.jsonl`: blocks, or lines for staging's chunks), so
the numbering follows the chain even where names are not zero-padded. Names
without a range, such as test1's `txexport-a?.log`, are read in name order,
after those with one. The source files carry no tx results, so any deploy of a
path, the first included, may be one the chain rejected.

Paths and file names come from the chain, rejected txs included, so a deploy
never fails the run over them. A deploy is skipped, with a warning, when:

- its path would leave the output dir (`..`, an absolute path), or a file name
  is not a plain name (`sub/x.gno`, an empty name) or its entry is null;
- a name in its path, or a file name, starts with `.` (git refuses `.git` and
  obeys `.gitignore`), or holds `~` or `\` (git's 8.3 and NTFS forms of
  `.git`), a NUL, or the `:` of the numbered dirs;
- a file is named `pkg_metadata.json`;
- a name in its path, numbered dir included, or a file name is longer than 255
  bytes, or a file's absolute path is 4,096 bytes or longer (Linux's
  `PATH_MAX`).

A skipped deploy takes no number: the path's other deploys are still written.

Every package dir, and every dir above it, is reserved before any deploy is
written. A first deploy that would write a file where a package needs a dir (a
package `r/x` with a file `license`, and a package `r/x/license`, whichever the
chain deployed first) moves to `<path>:1`, with a warning; the path's later
deploys follow at `<path>:2`, and so on.

test2 and test3 keep an older layout: deploys in `<path>:<block height>`, the
first one also in `<path>`, except test3's `r/sdm96/debugz`: its one deploy is
only in `debugz:364533`, and its `debugz` dir holds the `v1` and `v2`
sub-packages. Their trees hold every deploy of their backups, so
they are not rebuilt: their Makefiles do not set `EXTRACTOR_FLAGS`, so `make
extractor` there fails at the first deploy and keeps the tree. Passing
`EXTRACTOR_FLAGS=-legacy-mode` would rebuild them in the numbered layout,
dropping the block heights.
