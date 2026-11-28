// Package good is a correct lru implementation (reference for tests).
package lrugood

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh1/specs/lru/v1"

type cache struct {
	cap   int
	order []string
	vals  map[string]int
}

// New returns an empty cache.
func New(capacity int) lru.Cache { return &cache{cap: capacity, vals: map[string]int{}} }

func (c *cache) touch(k string) {
	out := c.order[:0:0]
	for _, x := range c.order {
		if x != k {
			out = append(out, x)
		}
	}
	c.order = append(out, k)
}

func (c *cache) Get(k string) (int, bool) {
	v, ok := c.vals[k]
	if ok {
		c.touch(k)
	}
	return v, ok
}

func (c *cache) Put(k string, v int) {
	if _, ok := c.vals[k]; !ok && len(c.order) == c.cap {
		delete(c.vals, c.order[0])
		c.order = c.order[1:]
	}
	c.vals[k] = v
	c.touch(k)
}

func (c *cache) Len() int { return len(c.order) }
