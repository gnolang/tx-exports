package bloomfilter

import (
	"crypto/sha256"
)

// Filter is a simple Bloom filter backed by a bit array, using k
// independent hash functions derived from a single sha256 digest.
type Filter struct {
	bits    []byte
	numBits int64
	k       int
}

// New creates a new Bloom filter with the given bit array size and number
// of hash functions.
func New(numBits int64, k int) *Filter {
	if numBits <= 0 {
		panic("bloomfilter: numBits must be positive")
	}
	if k <= 0 {
		panic("bloomfilter: k must be positive")
	}
	numBytes := (numBits + 7) / 8
	return &Filter{
		bits:    make([]byte, numBytes),
		numBits: numBits,
		k:       k,
	}
}

// hashes derives k independent hash values from the input using sha256
// with a counter as domain separator (simple double hashing scheme).
func (f *Filter) hashes(data []byte) []int64 {
	out := make([]int64, f.k)
	for i := 0; i < f.k; i++ {
		buf := make([]byte, 0, len(data)+1)
		buf = append(buf, byte(i))
		buf = append(buf, data...)
		sum := sha256.Sum256(buf)
		var v uint64
		for _, b := range sum[:8] {
			v = (v << 8) | uint64(b)
		}
		out[i] = int64(v % uint64(f.numBits))
	}
	return out
}

func (f *Filter) setBit(pos int64) {
	byteIdx := pos / 8
	bitIdx := uint(pos % 8)
	f.bits[byteIdx] |= 1 << bitIdx
}

func (f *Filter) getBit(pos int64) bool {
	byteIdx := pos / 8
	bitIdx := uint(pos % 8)
	return f.bits[byteIdx]&(1<<bitIdx) != 0
}

// Add inserts an item into the filter.
func (f *Filter) Add(data []byte) {
	for _, pos := range f.hashes(data) {
		f.setBit(pos)
	}
}

// MightContain reports whether the item may have been added. False
// positives are possible; false negatives are not.
func (f *Filter) MightContain(data []byte) bool {
	for _, pos := range f.hashes(data) {
		if !f.getBit(pos) {
			return false
		}
	}
	return true
}

// NumBits returns the size of the underlying bit array.
func (f *Filter) NumBits() int64 {
	return f.numBits
}

// K returns the number of hash functions used.
func (f *Filter) K() int {
	return f.k
}
