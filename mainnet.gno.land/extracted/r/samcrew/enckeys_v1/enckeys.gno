// Package enckeys_v1 is an ownerless public encryption-key directory.
// Keys are announcements by accounts, not attestations of identity, custody,
// recovery strength or successful decryption. There is no fee, admin or pause.
package enckeys_v1

import (
	"chain"
	"chain/runtime"
	"crypto/bech32"
	"encoding/base64"
	"encoding/hex"
	"strconv"

	"gno.land/p/samcrew/avl"
)

const SuiteXWingV1 = "xwing-v1"
const PublicKeyBytes = 1216

type keyRecord struct {
	Generation uint64
	PublicKey  []byte
	Operation  [16]byte
	Height     int64
	Revoked    bool
}

var keys = avl.NewTree()

// RegisterKey replaces the caller's announcement using an optimistic lock.
// expectedGeneration is zero only for first registration. A revoked generation
// is retained forever; re-registering cannot reuse an old identity generation.
func RegisterKey(cur realm, suite string, expectedGeneration uint64, publicKey []byte, opID [16]byte) uint64 {
	caller := user(cur)
	checkSuite(suite)
	if len(publicKey) != PublicKeyBytes {
		panic("enckeys: bad public key length")
	}
	old := current(caller)
	checkUpdate(old, expectedGeneration, opID)
	rec := &keyRecord{Generation: expectedGeneration + 1, PublicKey: clone(publicKey), Operation: opID, Height: runtime.ChainHeight()}
	keys.Set(string(caller), rec)
	emit(caller, rec, "registered")
	return rec.Generation
}

// RevokeKey removes the active key but retains the generation and receipt.
// Historical announcements and wraps remain public chain history.
func RevokeKey(cur realm, suite string, expectedGeneration uint64, opID [16]byte) uint64 {
	caller := user(cur)
	checkSuite(suite)
	old := current(caller)
	checkUpdate(old, expectedGeneration, opID)
	if old == nil || old.Revoked {
		panic("enckeys: no active key")
	}
	rec := &keyRecord{Generation: expectedGeneration + 1, Operation: opID, Height: runtime.ChainHeight(), Revoked: true}
	keys.Set(string(caller), rec)
	emit(caller, rec, "revoked")
	return rec.Generation
}

// GetKey returns a defensive copy; generation is still returned after revoke.
func GetKey(addr address, suite string) (publicKey []byte, generation uint64, active bool) {
	checkSuite(suite)
	rec := current(CanonicalAddress(addr))
	if rec == nil {
		return nil, 0, false
	}
	return clone(rec.PublicKey), rec.Generation, !rec.Revoked
}

// KeyJSON serializes all chain integers as decimal strings. op_id and height
// identify the last successful mutation for recovery from an unknown outcome.
func KeyJSON(addr address, suite string) string {
	checkSuite(suite)
	who := CanonicalAddress(addr)
	rec := current(who)
	prefix := `{"address":` + strconv.Quote(string(who)) + `,"suite":"xwing-v1"`
	if rec == nil {
		return prefix + `,"generation":"0","active":false,"public_key":"","op_id":"","height":"0"}`
	}
	return prefix + `,"generation":` + strconv.Quote(strconv.FormatUint(rec.Generation, 10)) + `,"active":` + strconv.FormatBool(!rec.Revoked) + `,"public_key":` + strconv.Quote(base64.StdEncoding.EncodeToString(rec.PublicKey)) + `,"op_id":` + strconv.Quote(hex.EncodeToString(rec.Operation[:])) + `,"height":` + strconv.Quote(strconv.FormatInt(rec.Height, 10)) + `}`
}

func Render(path string) string {
	if path == "" {
		return "# Encryption key directory\n\nAccount announcements for the xwing-v1 suite. Revocation does not erase chain history.\n"
	}
	return "````json\n" + KeyJSON(address(path), SuiteXWingV1) + "\n````"
}

// CanonicalAddress accepts the chain's four checksum/case spellings but always
// returns the lowercase original bech32 spelling that realm callers use.
func CanonicalAddress(addr address) address {
	if len(string(addr)) != 40 {
		panic("enckeys: invalid address")
	}
	hrp, raw, err := bech32.DecodeToBase256(string(addr))
	if err != nil || hrp != "g" || len(raw) != 20 {
		panic("enckeys: invalid address")
	}
	out, err := bech32.EncodeFromBase256("g", raw)
	if err != nil {
		panic("enckeys: invalid address")
	}
	return address(out)
}

func user(cur realm) address {
	if !cur.IsCurrent() {
		panic("enckeys: stale realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("enckeys: call directly from your account")
	}
	assertNoCoins()
	return cur.Previous().Address()
}
func checkSuite(suite string) {
	if suite != SuiteXWingV1 {
		panic("enckeys: unknown suite")
	}
}
func current(addr address) *keyRecord {
	v, ok := keys.Get(string(addr))
	if !ok {
		return nil
	}
	return v.(*keyRecord)
}
func checkUpdate(old *keyRecord, expected uint64, op [16]byte) {
	generation := uint64(0)
	if old != nil {
		generation = old.Generation
	}
	if generation != expected {
		panic("enckeys: stale generation")
	}
	if expected == ^uint64(0) {
		panic("enckeys: generation exhausted")
	}
	if op == ([16]byte{}) {
		panic("enckeys: empty operation id")
	}
	if old != nil && old.Operation == op {
		panic("enckeys: operation id reused")
	}
}
func clone(b []byte) []byte { return append([]byte(nil), b...) }
func emit(addr address, rec *keyRecord, action string) {
	chain.Emit("EncryptionKey", "address", string(addr), "suite", SuiteXWingV1, "generation", strconv.FormatUint(rec.Generation, 10), "action", action, "op_id", hex.EncodeToString(rec.Operation[:]))
}
