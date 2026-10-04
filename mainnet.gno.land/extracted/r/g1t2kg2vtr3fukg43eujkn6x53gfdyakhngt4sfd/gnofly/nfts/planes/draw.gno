package planes

import (
	"chain/runtime"
	"crypto/sha256"
	"encoding/binary"
	"time"
)

// Planes are minted in a random order: each mint draws one of the ids not
// minted yet. The id drawn is the token id and the row of the table, so
// whoever draws 777 gets the SuperGnome.
//
// The pool of ids left is a byte string of two bytes per id, big-endian,
// 1554 bytes at deploy: a slice of 777 int64 would cost several times the
// storage. A draw takes the id at a random index and moves the last id into
// its place (swap-remove), so every id comes out exactly once and a draw
// costs the same at any point of the sale.
//
// The randomness is pseudo-random, from what a realm can see: the sha256 of
// the block height, the block time, the minter, the count minted so far and
// the hash of the previous draw. A validator could nudge the block time, a
// user could try to time their block; nobody can see a draw and undo it,
// because Mint only accepts direct user calls (a contract cannot call Mint,
// look at the id and panic to try again). That is enough for this
// collection; it is not for anything with money riding on the outcome.

// pool holds the ids not minted yet, two bytes each. Its length over two is
// how many are left.
var pool []byte

// mintedBits has one bit per id, set once the id is minted (burned or not):
// what tells a burned plane from one not minted yet, without scanning pool.
var mintedBits []byte

// lastDraw is the hash of the previous draw, chained into the next.
var lastDraw [32]byte

// testDraw, when set by a test, replaces the hash to pick an index in a pool
// of n ids. It is never set outside the tests.
var testDraw func(n int) int

// resetPool fills the pool with every id, from 777 down to 1, and seeds the
// chain of draws from the realm's path.
func resetPool(pkgPath string) {
	pool = make([]byte, 2*supply)
	for i := int64(0); i < supply; i++ {
		binary.BigEndian.PutUint16(pool[2*i:], uint16(supply-i))
	}
	mintedBits = make([]byte, (supply+7)/8)
	lastDraw = sha256.Sum256([]byte(pkgPath))
}

// left returns how many ids are not minted yet.
func left() int64 {
	return int64(len(pool) / 2)
}

// drawHash is the hash a draw picks its index from. It is a pure function of
// its inputs, so that the tests can check what moves it.
func drawHash(height, nanos int64, minter address, minted int64, prev [32]byte) [32]byte {
	buf := make([]byte, 0, 8+8+len(minter)+8+32)
	buf = binary.BigEndian.AppendUint64(buf, uint64(height))
	buf = binary.BigEndian.AppendUint64(buf, uint64(nanos))
	buf = append(buf, minter...)
	buf = binary.BigEndian.AppendUint64(buf, uint64(minted))
	buf = append(buf, prev[:]...)
	return sha256.Sum256(buf)
}

// drawID takes one id out of the pool, at random, for minter, and marks it
// minted. The pool must not be empty.
func drawID(minter address) int64 {
	n := len(pool) / 2
	var i int
	if testDraw != nil {
		i = testDraw(n)
	} else {
		lastDraw = drawHash(runtime.ChainHeight(), time.Now().UnixNano(), minter, Minted(), lastDraw)
		// The first 8 bytes modulo the pool size: the bias of a modulo of
		// 2^64 by at most 777 is under 777/2^64, nothing.
		i = int(binary.BigEndian.Uint64(lastDraw[:8]) % uint64(n))
	}
	id := int64(binary.BigEndian.Uint16(pool[2*i:]))
	copy(pool[2*i:2*i+2], pool[2*(n-1):2*n])
	pool = pool[:2*(n-1)]
	mintedBits[(id-1)/8] |= 1 << uint((id-1)%8)
	return id
}

// wasMinted reports whether id was ever minted, burned since or not.
func wasMinted(id int64) bool {
	if id < 1 || id > supply {
		return false
	}
	return mintedBits[(id-1)/8]&(1<<uint((id-1)%8)) != 0
}
