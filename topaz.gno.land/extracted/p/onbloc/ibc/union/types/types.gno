package types

import (
	"encoding/hex"
	"strconv"
)

type ClientId uint32

func (id ClientId) String() string {
	return strconv.FormatUint(uint64(id), 10)
}

type ConnectionId uint32

func (id ConnectionId) String() string {
	return strconv.FormatUint(uint64(id), 10)
}

type Timestamp uint64

func (ts Timestamp) String() string {
	return strconv.FormatUint(uint64(ts), 10)
}

type Bytes []byte

func (bz Bytes) String() string {
	return "0x" + hex.EncodeToString(bz)
}

func (bz Bytes) Bytes() []byte {
	out := make([]byte, len(bz))
	copy(out, bz)

	return out
}

// Clone returns a fresh Bytes detached from any external/readonly realm
// ownership of bz.
//
// Under gno's InterRealm v2 borrow rules a value that crossed a realm boundary
// is externally stored, and a direct slice->slice conversion of it (a plain
// types.Bytes->[]byte cast, or a []byte->string->[]byte round-trip, which gno
// elides) keeps the foreign ownership and panics with "illegal conversion of
// readonly or externally stored value" when later stored or re-emitted. copy is
// an element-wise read, not a conversion, so it is permitted on a readonly
// source and yields a value owned by the caller's realm. Use Clone before
// persisting or re-emitting Bytes that arrived from another realm.
func (bz Bytes) Clone() Bytes {
	return Bytes(bz.Bytes())
}

// CloneBytes returns a fresh copy of b, or nil for nil input. It is the []byte
// counterpart of Bytes.Clone: realm packages use it to detach the InterRealm v2
// ownership of a slice that crossed a realm boundary before storing or
// re-emitting it. copy is an element-wise read (permitted on a foreign/readonly
// slice); a slice->slice conversion or a []byte->string->[]byte round-trip (which
// gno elides) would keep the foreign ownership and later panic with "illegal
// conversion of readonly or externally stored value".
func CloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}

	out := make([]byte, len(b))
	copy(out, b)

	return out
}

type H256 [32]byte

func (h H256) String() string {
	return "0x" + hex.EncodeToString(h[:])
}

type ClientType string

func (ct ClientType) String() string {
	return string(ct)
}
