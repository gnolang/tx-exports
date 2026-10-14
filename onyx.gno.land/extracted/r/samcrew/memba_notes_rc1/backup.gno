package memba_notes_rc1

import (
	"bytes"
	"chain/runtime"
	"crypto/bech32"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"gno.land/p/samcrew/avl"
	keys "gno.land/r/samcrew/enckeys_v1"
	"strconv"
	"strings"
)

const MaxBackupBytes = 365

type backupRecord struct {
	Record               []byte
	Mode                 uint8
	Generation, Revision uint64
	PublicKeyHash        []byte
	Last                 receipt
}

var backupLatest = avl.NewTree()
var backups = avl.NewTree()

// A wallet-protected historical backup cannot become Vault-safe by relabelling.
var standardBackupKeys = avl.NewTree()

func backupKey(who address, generation uint64) string {
	s := strconv.FormatUint(generation, 10)
	return string(who) + ":" + strings.Repeat("0", 20-len(s)) + s
}
func backupText(record []byte, pos, cap int) (string, int) {
	if pos+4 > len(record) {
		panic("notes: backup truncated")
	}
	size := int(binary.BigEndian.Uint32(record[pos : pos+4]))
	pos += 4
	if size < 1 || size > cap || pos+size > len(record) {
		panic("notes: backup text length")
	}
	for _, b := range record[pos : pos+size] {
		if b < 33 || b > 126 {
			panic("notes: backup ascii")
		}
	}
	return string(record[pos : pos+size]), pos + size
}
func validateBackup(who address, record []byte) (uint8, uint64, []byte) {
	if len(record) < 185 || len(record) > MaxBackupBytes || string(record[:4]) != "MNKB" || record[4] != 1 || record[5] != 1 {
		panic("notes: backup format")
	}
	mode := record[6]
	kdf := record[7]
	memory := binary.BigEndian.Uint32(record[8:12])
	passes := binary.BigEndian.Uint32(record[12:16])
	lanes := record[16]
	if !(mode == 1 && kdf == 1 && memory == 0 && passes == 0 && lanes == 0 || mode == 2 && kdf == 2 && memory == 65536 && passes == 3 && lanes == 1) {
		panic("notes: backup kdf profile")
	}
	chain, pos := backupText(record, 33, 64)
	realmPath, pos := backupText(record, pos, 128)
	if chain != runtime.ChainID() || realmPath != RealmPath || len(record) != pos+132 {
		panic("notes: backup network/length")
	}
	encoded, err := bech32.EncodeFromBase256("g", record[pos:pos+20])
	if err != nil || address(encoded) != who {
		panic("notes: backup address")
	}
	pos += 20
	generation := binary.BigEndian.Uint64(record[pos : pos+8])
	pos += 8
	hash := record[pos : pos+32]
	pk, gen, active := keys.GetKey(who, keys.SuiteXWingV1)
	h := sha256.Sum256(pk)
	if generation == 0 || generation != gen || !active || !bytes.Equal(hash, h[:]) {
		panic("notes: backup registry identity")
	}
	return mode, generation, copied(hash)
}
func SetSeedBackup(cur realm, baseRevision uint64, record []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	if !cur.Previous().IsUserCall() {
		panic("notes: backup directly from account")
	}
	if opID == ([16]byte{}) || baseRevision == ^uint64(0) {
		panic("notes: invalid backup operation")
	}
	var revision uint64
	if v, ok := backupLatest.Get(string(who)); ok {
		r := v.(*backupRecord)
		revision = r.Revision
		if r.Last.Operation == opID {
			panic("notes: operation id reused")
		}
	}
	if revision != baseRevision {
		panic("notes: stale backup revision")
	}
	mode, generation, hash := validateBackup(who, record)
	exposureKey := string(who) + ":" + hex.EncodeToString(hash)
	if mode == 2 {
		if _, seen := standardBackupKeys.Get(exposureKey); seen {
			panic("notes: vault requires independent identity")
		}
	} else {
		standardBackupKeys.Set(exposureKey, true)
	}
	r := &backupRecord{copied(record), mode, generation, revision + 1, hash, receipt{opID, who, runtime.ChainHeight()}}
	backups.Set(backupKey(who, generation), r)
	backupLatest.Set(string(who), r)
}
func backupJSON(r *backupRecord, withRecord bool) string {
	s := `{"mode":` + strconv.Itoa(int(r.Mode)) + `,"suite":"xwing-v1","generation":` + u(r.Generation) + `,"revision":` + u(r.Revision) + `,"public_key_hash":` + blob(r.PublicKeyHash) + `,"op_id":` + q(idText(r.Last.Operation)) + `,"actor":` + q(string(r.Last.Actor)) + `,"height":` + q(strconv.FormatInt(r.Last.Height, 10))
	if withRecord {
		s += `,"record":` + blob(r.Record)
	}
	return s + `}`
}
func SeedBackupJSON(who address) string {
	v, ok := backupLatest.Get(string(keys.CanonicalAddress(who)))
	if !ok {
		return "null"
	}
	return backupJSON(v.(*backupRecord), true)
}
func SeedBackupAtJSON(who address, generation uint64) string {
	v, ok := backups.Get(backupKey(keys.CanonicalAddress(who), generation))
	if !ok {
		return "null"
	}
	return backupJSON(v.(*backupRecord), true)
}
func SeedBackupsJSON(who address, cursor uint64, limit int) string {
	who = keys.CanonicalAddress(who)
	if limit < 1 || limit > MaxPage {
		panic("notes: page limit")
	}
	items := []string{}
	var next uint64
	backups.Iterate(backupKey(who, cursor), string(who)+":\xff", func(k string, v interface{}) bool {
		r := v.(*backupRecord)
		if r.Generation <= cursor {
			return false
		}
		items = append(items, backupJSON(r, false))
		next = r.Generation
		return len(items) == limit
	})
	if len(items) < limit {
		next = 0
	}
	return `{"items":[` + strings.Join(items, ",") + `],"next_cursor":` + u(next) + `}`
}
