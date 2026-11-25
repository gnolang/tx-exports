package heirloom

import (
	"chain/runtime"
	"strings"

	"gno.land/p/moul/fifo/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const recentLen = 5

type store struct {
	lastID         seqid.ID
	wills          avl.Tree
	activeByOwner  avl.Tree
	ownerWills     avl.Tree
	heirWills      avl.Tree
	successorWills avl.Tree
	rights         succession
	totalGNOT      int64
	releasedCount  int
	recent         *fifo.List
}

var (
	state    = newStore()
	pkgPath  string
	webPath  string
	selfAddr address
)

func init(cur realm) {
	pkgPath = cur.PkgPath()
	webPath = strings.TrimPrefix(pkgPath, runtime.ChainDomain())
	selfAddr = cur.Address()
}

func newStore() *store {
	return &store{recent: fifo.New(recentLen)}
}
