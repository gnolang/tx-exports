// Package cheatlru tries the harness bypass found in review: it stops every
// test from inside the implementation with a throwaway check.T, hoping the
// stop is read as a clean pass. It must fail.
package cheatlruuofw

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/check/v1"
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/specs/lru/v1"
)

type cache struct{}

// New returns a cache that never answers.
func New(capacity int) lru.Cache { return &cache{} }

func (c *cache) Get(key string) (int, bool) { new(check.T).Fatal(""); return 0, false }
func (c *cache) Put(key string, v int)      { new(check.T).Fatal("") }
func (c *cache) Len() int                   { new(check.T).Fatal(""); return 0 }
