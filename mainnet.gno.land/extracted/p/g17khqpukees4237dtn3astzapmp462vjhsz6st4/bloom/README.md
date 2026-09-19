# Bloom Package

Package implements a Bloom filter, a space-efficient probabilistic data structure
used to test whether an element is a member of a set.

A Bloom filter never returns a false negative. If `Contains` returns `false`, the
element was definitely never added. It may return a false positive, `Contains` can
return `true` for an element that was never added. This trade-off lets the filter
use far less memory than storing the elements themselves, which makes it useful for
membership checks such as caches, deduplication, or "have I seen this before?" tests.

Repository can be found at [jeronimoalbi/gnome](https://github.com/jeronimoalbi/gnome),
as part of `jeronimoalbi`'s Gno smart contracts monorepo.

## Usage

[embedmd]:# (filetests/readme_filetest.gno go)
```go
package main

import "gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bloom"

func main() {
	// Create a filter expecting up to 1000 items with a 1% false-positive rate.
	b := bloom.New(1000, 0.01)

	b.AddString("apple").AddString("banana")

	println("Has apple:", b.ContainsString("apple"))
	println("Has banana:", b.ContainsString("banana"))
	println("Has cherry:", b.ContainsString("cherry"))
}

// Output:
// Has apple: true
// Has banana: true
// Has cherry: false
```
