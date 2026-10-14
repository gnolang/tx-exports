package memba_notes_rc1

import (
	"bytes"
	"gno.land/p/samcrew/avl"
	"strconv"
	"strings"
)

type epochRecord struct {
	Epoch                             uint32
	Manifest, Commitment, RevealedKey []byte
}

var epochs = avl.NewTree()

func epochKey(id [16]byte, epoch uint32) string {
	s := strconv.FormatUint(uint64(epoch), 10)
	return idText(id) + ":" + strings.Repeat("0", 10-len(s)) + s
}
func getEpoch(id [16]byte, epoch uint32) *epochRecord {
	v, ok := epochs.Get(epochKey(id, epoch))
	if !ok {
		panic("notes: epoch missing")
	}
	return v.(*epochRecord)
}
func privateWritable(n *note) {
	if encrypted(n.Mode) && len(getEpoch(n.ID, n.Epoch).RevealedKey) != 0 {
		panic("notes: revealed epoch requires rotation")
	}
}
func setRecipients(n *note, list []recipient) {
	n.Readers = nil
	n.Writers = nil
	for _, r := range list {
		n.Readers = append(n.Readers, r.Who)
		if r.Writer && r.Who != n.Owner {
			n.Writers = append(n.Writers, r.Who)
		}
	}
}
func initializeEncrypted(n *note, access, kc []byte) {
	validateCommitment(kc)
	list := parseManifest(access, 1, n.Owner, n.Mode)
	validateCipher(n.Title, 1, 1, 1, MaxCipherTitleBytes)
	validateCipher(n.Body, 1, 2, 1, MaxCipherBodyBytes)
	n.Epoch = 1
	n.Commitment = copied(kc)
	setRecipients(n, list)
	epochs.Set(epochKey(n.ID, 1), &epochRecord{Epoch: 1, Manifest: copied(access), Commitment: copied(kc)})
}

// Rotate installs the entire next epoch in one transaction. Historical epoch
// records stay available until Delete+boundedPurge; rotation never scans them.
func Rotate(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, mode uint8, title, body, manifest, kc []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRotate(cur, who, id, baseRevision, expectedEpoch, mode, title, body, manifest, kc, opID)
}
func mutateRotate(cur realm, who address, id [16]byte, baseRevision uint64, expectedEpoch uint32, mode uint8, title, body, manifest, kc []byte, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if !encrypted(n.Mode) || !encrypted(mode) {
		panic("notes: encrypted rotation required")
	}
	if expectedEpoch != n.Epoch || n.Epoch == ^uint32(0) {
		panic("notes: stale/exhausted epoch")
	}
	if n.TitleRevision == ^uint64(0) || n.BodyRevision == ^uint64(0) {
		panic("notes: field revision exhausted")
	}
	ep := n.Epoch + 1
	validateCommitment(kc)
	if bytes.Equal(kc, n.Commitment) {
		panic("notes: fresh epoch commitment required")
	}
	list := parseManifest(manifest, ep, manifestOwner(n), mode)
	validateCipher(title, ep, 1, n.TitleRevision+1, MaxCipherTitleBytes)
	validateCipher(body, ep, 2, n.BodyRevision+1, MaxCipherBodyBytes)
	operation(n, opID)
	unindex(n)
	n.Mode = mode
	n.Epoch = ep
	n.Title = copied(title)
	n.Body = copied(body)
	n.BodyBytes = len(body)
	n.TitleRevision++
	n.BodyRevision++
	n.Commitment = copied(kc)
	n.PendingOwner = ""
	setRecipients(n, list)
	index(n)
	epochs.Set(epochKey(id, ep), &epochRecord{Epoch: ep, Manifest: copied(manifest), Commitment: copied(kc)})
	acknowledgeRequests(n, who, opID)
	bump(n, who, opID, "rotate")
}

// ApplyAccess grants access to the CURRENT epoch and its history. Removing a
// reader/writer or changing link scope requires Rotate, never this entrypoint.
func ApplyAccess(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, mode uint8, manifest []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateApplyAccess(cur, who, id, baseRevision, expectedEpoch, mode, manifest, opID)
}
func mutateApplyAccess(cur realm, who address, id [16]byte, baseRevision uint64, expectedEpoch uint32, mode uint8, manifest []byte, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	privateWritable(n)
	if !encrypted(n.Mode) || expectedEpoch != n.Epoch || !(mode == n.Mode || n.Mode == ModePrivate && mode == ModeShared) {
		panic("notes: access transition requires rotation")
	}
	list := parseManifest(manifest, n.Epoch, manifestOwner(n), mode)
	for _, a := range n.Readers {
		found := false
		for _, r := range list {
			if r.Who == a {
				found = true
				if writer(n, a) && !r.Writer {
					panic("notes: writer removal requires rotation")
				}
			}
		}
		if !found {
			panic("notes: reader removal requires rotation")
		}
	}
	operation(n, opID)
	unindex(n)
	n.Mode = mode
	setRecipients(n, list)
	index(n)
	getEpoch(id, n.Epoch).Manifest = copied(manifest)
	acknowledgeRequests(n, who, opID)
	bump(n, who, opID, "access")
}
func Publish(cur realm, id [16]byte, baseRevision uint64, mode uint8, title, body []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutatePublish(cur, who, id, baseRevision, mode, title, body, opID)
}
func mutatePublish(cur realm, who address, id [16]byte, baseRevision uint64, mode uint8, title, body []byte, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	if !encrypted(n.Mode) || !public(mode) {
		panic("notes: publish transition")
	}
	if n.TitleRevision == ^uint64(0) || n.BodyRevision == ^uint64(0) {
		panic("notes: field revision exhausted")
	}
	validatePublic(title, body)
	operation(n, opID)
	unindex(n)
	n.Mode = mode
	n.Title = copied(title)
	n.Body = copied(body)
	n.BodyBytes = len(body)
	n.TitleRevision++
	n.BodyRevision++
	n.Listed = true
	n.Readers = nil
	n.Commitment = nil
	n.PendingOwner = ""
	index(n)
	bump(n, who, opID, "publish")
}
func Reveal(cur realm, id [16]byte, baseRevision uint64, epoch uint32, key []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateReveal(cur, who, id, baseRevision, epoch, key, opID)
}
func mutateReveal(cur realm, who address, id [16]byte, baseRevision uint64, epoch uint32, key []byte, opID [16]byte) {
	n := live(id)
	owner(n, who)
	expected(n, baseRevision)
	ep := getEpoch(id, epoch)
	if len(key) != 32 || len(ep.RevealedKey) != 0 || !bytes.Equal(epochCommitment(id, epoch, key), ep.Commitment) {
		panic("notes: invalid/already revealed key")
	}
	operation(n, opID)
	ep.RevealedKey = copied(key)
	bumpHistory(n, who, opID, "reveal", `,"target_epoch":` + u(uint64(epoch)))
}
func epochJSON(ep *epochRecord, withManifest bool) string {
	out := `{"epoch":` + u(uint64(ep.Epoch)) + `,"commitment":` + blob(ep.Commitment) + `,"revealed_key":` + blob(ep.RevealedKey)
	if withManifest {
		out += `,"manifest":` + blob(ep.Manifest)
	}
	return out + `}`
}
func EpochJSON(idHex string, epoch uint32) string {
	id := readID(idHex)
	v, ok := epochs.Get(epochKey(id, epoch))
	if !ok {
		return "null"
	}
	return epochJSON(v.(*epochRecord), true)
}
func EpochsJSON(idHex string, cursor uint32, limit int) string {
	id := readID(idHex)
	find(id)
	if limit < 1 || limit > MaxPage {
		panic("notes: page limit")
	}
	items := []string{}
	var next uint32
	epochs.Iterate(epochKey(id, cursor), idText(id)+":\xff", func(k string, v interface{}) bool {
		ep := v.(*epochRecord)
		if ep.Epoch <= cursor {
			return false
		}
		items = append(items, epochJSON(ep, false))
		next = ep.Epoch
		return len(items) == limit
	})
	if len(items) < limit {
		next = 0
	}
	return `{"items":[` + strings.Join(items, ",") + `],"next_cursor":` + u(uint64(next)) + `}`
}
func ReadersJSON(idHex string) string {
	n := find(readID(idHex))
	out := "["
	for i, a := range n.Readers {
		if i > 0 {
			out += ","
		}
		out += q(string(a))
	}
	return out + "]"
}

func manifestOwner(n *note) address {
	if n.OwnerIsRealm {
		return ""
	}
	return n.Owner
}

// Ownership changes do not silently revoke an existing manifest writer.
// Revocation requires the new owner to rotate; old key knowledge also remains.
func preserveTransferredWriters(n *note) {
	data := getEpoch(n.ID, n.Epoch).Manifest
	n.Writers = nil
	for i := 0; i < int(data[1]); i++ {
		off := 2 + i*ManifestEntryBytes
		if data[off+20] == 1 {
			who := manifestAddress(data[off : off+20])
			if who != n.Owner {
				n.Writers = append(n.Writers, who)
			}
		}
	}
}

func WrapJSON(idHex string, epoch uint32, who address) string {
	id := readID(idHex)
	who = canonicalRecipient(who)
	v, ok := epochs.Get(epochKey(id, epoch))
	if !ok {
		return "null"
	}
	data := v.(*epochRecord).Manifest
	for i := 0; i < int(data[1]); i++ {
		off := 2 + i*ManifestEntryBytes
		if manifestAddress(data[off:off+20]) == who {
			return wrapJSON(data[off:off+ManifestEntryBytes], epoch, who)
		}
	}
	return "null"
}

// RefreshOwnWrap changes only the caller's identity envelope. It cannot change
// roles, readers, modes or epochs, and never rewrites anybody else's recovery.
func RefreshOwnWrap(cur realm, id [16]byte, baseRevision uint64, expectedEpoch uint32, manifest []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	n := live(id)
	expected(n, baseRevision)
	privateWritable(n)
	if !cur.Previous().IsUserCall() || !encrypted(n.Mode) || expectedEpoch != n.Epoch || !contains(n.Readers, who) {
		panic("notes: current reader required")
	}
	// A reader who accepted Shared ownership may retain a false explicit writer
	// flag: ownership is implicit authority. Self-refresh preserves that flag.
	manifestAccountOwner := address("")
	if n.Mode == ModePrivate {
		manifestAccountOwner = n.Owner
	}
	parseManifestFor(manifest, n.Epoch, manifestAccountOwner, n.Mode, who)
	old := getEpoch(id, n.Epoch).Manifest
	if len(old) != len(manifest) {
		panic("notes: self refresh cannot change readers")
	}
	changed := false
	for i := 0; i < int(old[1]); i++ {
		off := 2 + i*ManifestEntryBytes
		previous := old[off : off+ManifestEntryBytes]
		next := manifest[off : off+ManifestEntryBytes]
		if manifestAddress(previous[:20]) == who {
			if string(previous[:21]) != string(next[:21]) {
				panic("notes: self refresh cannot change role")
			}
			changed = string(previous) != string(next)
		} else if string(previous) != string(next) {
			panic("notes: self refresh cannot change another wrap")
		}
	}
	if !changed {
		panic("notes: wrap unchanged")
	}
	operation(n, opID)
	getEpoch(id, n.Epoch).Manifest = copied(manifest)
	bump(n, who, opID, "self-rekey")
}
