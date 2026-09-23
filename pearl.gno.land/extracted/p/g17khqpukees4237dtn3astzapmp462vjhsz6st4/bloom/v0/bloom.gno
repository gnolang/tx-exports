// Package bloom implements a Bloom filter, a space-efficient probabilistic
// data structure used to test whether an element is a member of a set.
//
// A Bloom filter never reports a false negative; If Contains returns false,
// the element was definitely never added. It may report a false positive.
//
// Contains can return true for an element that was never added. The chance of
// a false positive grows as more elements are added and can be traded against
// memory usage when the filter is created.
package bloom

import (
	"math"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bitset/v0"
	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/murmur3/v0"
)

// Bloom is a probabilistic set-membership filter.
type Bloom struct {
	bits bitset.BitSet
	m    uint64 // Number of bits in the filter
	k    uint64 // Number of hash positions set per element
}

// NewWithMK creates a filter with an explicit bit-array size m and hash count k.
// It is the low-level constructor for callers who already know the parameters;
// Most users should prefer New. Both m and k are clamped to a minimum of 1.
func NewWithMK(m, k uint64) *Bloom {
	if m < 1 {
		m = 1
	}

	if k < 1 {
		k = 1
	}

	return &Bloom{
		bits: bitset.New(m),
		m:    m,
		k:    k,
	}
}

// New creates a filter sized to hold up to maxItems elements while keeping the
// false-positive probability around falsePositiveRate (for example 0.01 for 1%).
// It computes the optimal number of bits and hash functions and delegates to
// NewWithMK. Invalid inputs (maxItems == 0, or a rate outside the open interval
// (0, 1)) fall back to a minimal usable filter.
func New(maxItems uint64, falsePositiveRate float64) *Bloom {
	if maxItems == 0 || falsePositiveRate <= 0 || falsePositiveRate >= 1 {
		return NewWithMK(1, 1)
	}

	n := float64(maxItems)
	ln2 := math.Ln2

	// m = ceil( -(n * ln(p)) / (ln2)^2 )
	m := uint64(math.Ceil(-(n * math.Log(falsePositiveRate)) / (ln2 * ln2)))

	// k = round( (m/n) * ln2 )
	k := uint64(math.Round((float64(m) / n) * ln2))

	return NewWithMK(m, k)
}

// Capacity returns the capacity "m" of the filter.
func (b *Bloom) Capacity() uint64 {
	return b.m
}

// HashFunctions returns the number of hash functions "k" of the filter.
func (b *Bloom) HashFunctions() uint64 {
	return b.k
}

// Reset clears all values from the filter, keeping its capacity and hash count.
func (b *Bloom) Reset() *Bloom {
	b.bits.ClearAll()
	return b
}

// Add inserts data into the filter.
func (b *Bloom) Add(data []byte) *Bloom {
	h1, h2 := hashes(data)
	for i := uint64(0); i < b.k; i++ {
		b.bits.Set(b.index(h1, h2, i))
	}
	return b
}

// AddString inserts string data into the filter.
func (b *Bloom) AddString(data string) *Bloom {
	return b.Add([]byte(data))
}

// Contains checks whether data is possibly in the set.
// A false result means data was definitely never added.
// A true result means data was probably added but may be a false positive.
func (b *Bloom) Contains(data []byte) bool {
	h1, h2 := hashes(data)
	for i := uint64(0); i < b.k; i++ {
		if !b.bits.IsSet(b.index(h1, h2, i)) {
			return false
		}
	}
	return true
}

// ContainsString checks whether string data is possibly in the set.
// A false result means data was definitely never added.
// A true result means data was probably added but may be a false positive.
func (b *Bloom) ContainsString(data string) bool {
	return b.Contains([]byte(data))
}

// index returns the i-th bit position for an element using double hashing.
func (b *Bloom) index(h1, h2 uint32, i uint64) uint64 {
	return (uint64(h1) + i*uint64(h2)) % b.m
}

// hashes splits a single 64-bit MurmurHash3 hash of data into two 32-bit halves
// used as the seeds for double hashing.
func hashes(data []byte) (h1, h2 uint32) {
	sum := murmur3.Sum64(data)
	return uint32(sum >> 32), uint32(sum)
}
