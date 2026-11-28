// Package agentlru implements the Assertpay spec lru.
//
// Keys are kept in a slice ordered from least to most recently used,
// next to a map holding their values. Simple and fine for small caches.
package agentlruhgtj

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/specs/lru/v1"

type cache struct {
	capacity int
	order    []string // least recently used first
	vals     map[string]int
}

// New returns an empty cache holding at most capacity keys.
func New(capacity int) lru.Cache {
	return &cache{capacity: capacity, vals: map[string]int{}}
}

// Get returns the value for key and marks key as most recently used.
func (c *cache) Get(key string) (int, bool) {
	v, ok := c.vals[key]
	if ok {
		c.touch(key)
	}
	return v, ok
}

// Put sets key to v, evicting the least recently used key if full.
func (c *cache) Put(key string, v int) {
	if _, ok := c.vals[key]; ok {
		c.touch(key)
	} else {
		if len(c.order) >= c.capacity {
			delete(c.vals, c.order[0])
			c.order = c.order[1:]
		}
		c.order = append(c.order, key)
	}
	c.vals[key] = v
}

// Len is the number of keys held.
func (c *cache) Len() int { return len(c.order) }

// touch moves key to the most recently used end of the order.
func (c *cache) touch(key string) {
	for i, k := range c.order {
		if k == key {
			c.order = append(c.order[:i], c.order[i+1:]...)
			break
		}
	}
	c.order = append(c.order, key)
}
