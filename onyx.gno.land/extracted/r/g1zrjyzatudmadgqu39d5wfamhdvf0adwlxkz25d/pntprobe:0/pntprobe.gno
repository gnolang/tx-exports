// Package pntprobe checks whether a realm importing the registry's /p/nt
// libraries goes live.
package pntprobe

import (
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	tree bptree.BPTree
	last seqid.ID
)

func Size() int { return tree.Size() }

func Next() string { return sanitize.InlineText(last.String()) }
