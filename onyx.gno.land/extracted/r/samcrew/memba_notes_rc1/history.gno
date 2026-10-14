package memba_notes_rc1

import (
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"gno.land/p/samcrew/avl"
	"strconv"
	"strings"
)

// Bytes shares the note's committed array: fields are replaced, never mutated in
// place, so history stores each version once and a later commit frees nothing
// another account paid for. A moderator redaction clears Bytes and keeps Hash.
type historyBlob struct {
	Bytes    []byte
	Hash     string
	Redacted bool
}

// historyVersion is the public state recorded by one note-level event. It keeps
// only what the public history reads expose, never a copy of the live note: no
// private manifest, readers, commitment or receipts. Versions that leave a field
// unchanged share that field's blob.
type historyVersion struct {
	Revision, TitleRevision, BodyRevision, OwnerGeneration uint64
	Owner, PendingOwner                                    address
	Writers                                                []address
	PolicyRead, PolicyWrite, PolicyComment                 string
	Epoch                                                  uint32
	Mode                                                   uint8
	OwnerIsRealm, GovWriters, Listed, ModeratorHidden      bool
	Deleted, PublicWrites                                  bool
	Title, Body                                            *historyBlob
}

// historyInfo is kept on the public note itself (note.History); the note record
// is retained forever as a tombstone, so it needs no index of its own.
type historyInfo struct {
	StartRevision, StartBodyRevision, Head uint64
	Latest                                 *historyVersion
}

// One record per event. Operation and Comment hold the raw 16-byte ids ("" for
// none). Version is set on note-level events only; comment and cleanup events
// reuse the current state revision and record no version.
type historyEntry struct {
	Seq, Revision, Proposal          uint64
	Height                           int64
	Actor, Executor                  address
	Operation, Comment               string
	Action, GovernanceAction, Detail string
	Version                          *historyVersion
}

// historyComment keeps the first public version of a comment (Parent to Body,
// Parent as a raw id or "") and its latest presentation. Anchor and Body share
// the live comment's arrays, so a comment's text is stored once.
type historyComment struct {
	Parent                       string
	Author                       address
	BodyRevision                 uint64
	Epoch                        uint32
	CreatedHeight                int64
	Anchor, Body                 []byte
	AnchorHistory, ParentHistory bool
	LatestSeq                    uint64
	Deleted, Hidden, Resolved    bool
	Redacted                     bool
}
type historyCall struct {
	Executor  address
	Proposal  uint64
	Operation [16]byte
	Action    string
}

var historyEntries = avl.NewTree()
var historyComments = avl.NewTree()

// Only GovApply sets this while the existing busy guard excludes reentry.
var historyGov *historyCall

func historyKey(id [16]byte, seq uint64) string {
	s := strconv.FormatUint(seq, 10)
	return idText(id) + ":" + strings.Repeat("0", 20-len(s)) + s
}
func historyID(text string) [16]byte {
	id := readID(text)
	if id == ([16]byte{}) {
		panic("notes: empty history id")
	}
	return id
}
func historyGet(id [16]byte) *historyInfo {
	v, ok := notes.Get(idText(id))
	if !ok {
		return nil
	}
	return v.(*note).History
}
func historyEntryAt(id [16]byte, seq uint64) *historyEntry {
	v, ok := historyEntries.Get(historyKey(id, seq))
	if !ok {
		panic("notes: history gap")
	}
	return v.(*historyEntry)
}

// historyVersionAt returns the version recorded by the event with this seq, or
// nil when there is no such event or it is a comment/cleanup event.
func historyVersionAt(id [16]byte, seq uint64) *historyVersion {
	v, ok := historyEntries.Get(historyKey(id, seq))
	if !ok {
		return nil
	}
	return v.(*historyEntry).Version
}

// historyRevisionEntry finds the note-level event of a public state revision
// without an index. Entries are contiguous from seq 1 and their state revision
// never decreases; each state revision since publication is recorded by exactly
// one note-level event, the first entry carrying it.
func historyRevisionEntry(id [16]byte, h *historyInfo, revision uint64) *historyEntry {
	if revision < h.StartRevision || revision > h.Latest.Revision {
		return nil
	}
	lo, hi := uint64(1), h.Head
	for lo < hi {
		mid := lo + (hi-lo)/2
		if historyEntryAt(id, mid).Revision < revision {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	e := historyEntryAt(id, lo)
	if e.Revision != revision || e.Version == nil {
		panic("notes: corrupt history")
	}
	return e
}
func historyBlobOf(data []byte) *historyBlob {
	hash := sha256.Sum256(data)
	return &historyBlob{Bytes: data, Hash: hex.EncodeToString(hash[:])}
}
func rawID(id [16]byte) string {
	if id == ([16]byte{}) {
		return ""
	}
	return string(id[:])
}
func historyNullableRaw(raw string) string {
	if raw == "" {
		return "null"
	}
	return q(hex.EncodeToString([]byte(raw)))
}
func historyAppend(n *note, who address, op, cid [16]byte, action, detail string) *historyEntry {
	h := n.History
	if h == nil || h.Head == ^uint64(0) {
		panic("notes: history unavailable/exhausted")
	}
	h.Head++
	e := &historyEntry{Seq: h.Head, Revision: n.Revision, Height: runtime.ChainHeight(), Actor: who, Operation: rawID(op), Comment: rawID(cid), Action: action, Detail: detail}
	if historyGov != nil {
		e.Executor, e.Proposal, e.GovernanceAction = historyGov.Executor, historyGov.Proposal, historyGov.Action
		e.Operation = rawID(historyGov.Operation)
	}
	if _, exists := historyEntries.Get(historyKey(n.ID, e.Seq)); exists {
		panic("notes: history collision")
	}
	historyEntries.Set(historyKey(n.ID, e.Seq), e)
	return e
}
func historyNote(n *note, who address, op [16]byte, action, extra string) {
	if !public(n.Mode) {
		return
	}
	h := n.History
	if h == nil {
		if action != "create" && action != "publish" {
			panic("notes: missing public history")
		}
		h = &historyInfo{StartRevision: n.Revision, StartBodyRevision: n.BodyRevision}
		n.History = h
	}
	previous := "null"
	mask := 0
	if h.Latest != nil {
		previous = u(h.Latest.Revision)
		if n.TitleRevision != h.Latest.TitleRevision {
			mask |= 1
		}
		if n.BodyRevision != h.Latest.BodyRevision {
			mask |= 2
		}
	}
	switch action {
	case "commit":
		action = "content-commit"
		extra = `,"field_mask":` + strconv.Itoa(mask)
	case "comments-mode":
		action = "comment-mode"
	case "policy":
		action = "policy-set"
	case "listing":
		action = "owner-listing"
	case "moderate-listing":
		action = "listing-moderation"
	case "delete":
		action = "note-delete"
	case "reveal":
		action = "legacy-epoch-reveal"
	case "owner-propose":
		if n.PendingOwner == "" {
			action = "owner-cancel"
		}
	}
	e := historyAppend(n, who, op, [16]byte{}, action, `{"snapshot_revision":`+u(n.Revision)+`,"previous_state_revision":`+previous+extra+`}`)
	v := &historyVersion{Revision: n.Revision, TitleRevision: n.TitleRevision, BodyRevision: n.BodyRevision, OwnerGeneration: n.OwnerGeneration,
		Owner: n.Owner, PendingOwner: n.PendingOwner, Writers: historyWriters(h.Latest, n.Writers),
		PolicyRead: n.Policies[0], PolicyWrite: n.Policies[1], PolicyComment: n.Policies[2], Epoch: n.Epoch, Mode: n.Mode,
		OwnerIsRealm: n.OwnerIsRealm, GovWriters: n.GovWriters, Listed: n.Listed, ModeratorHidden: n.ModeratorHidden,
		Deleted: n.Deleted, PublicWrites: publicWritesEnabled(n)}
	if !n.Deleted {
		if h.Latest != nil && h.Latest.TitleRevision == n.TitleRevision {
			v.Title = h.Latest.Title
		} else {
			v.Title = historyBlobOf(n.Title)
		}
		if h.Latest != nil && h.Latest.BodyRevision == n.BodyRevision {
			v.Body = h.Latest.Body
		} else {
			v.Body = historyBlobOf(n.Body)
		}
	}
	e.Version = v
	h.Latest = v
}

// historyWriters shares the previous version's writer list while it is
// unchanged. Recorded lists are never mutated, and the live list is never
// shared: a changed list is copied, since RemoveWriter edits it in place.
func historyWriters(latest *historyVersion, writers []address) []address {
	if latest != nil && len(latest.Writers) == len(writers) {
		same := true
		for i, who := range writers {
			if latest.Writers[i] != who {
				same = false
				break
			}
		}
		if same {
			return latest.Writers
		}
	}
	return copiedAddresses(writers)
}
func historyNullableText(s string) string {
	if s == "" {
		return "null"
	}
	return q(s)
}

// historyCommentDetail renders a comment reference; cid is the hex id and parent
// the raw parent id ("" for a top-level comment).
func historyCommentDetail(cid, parent string, revision, bodyRevision uint64, deleted, hidden, resolved bool, archived *historyComment) string {
	anchorRevision := "null"
	if archived.AnchorHistory {
		anchorRevision = u(bodyRevision)
	}
	return `{"comment_id":` + q(cid) + `,"comment_revision":` + u(revision) + `,"content_ref":` + q(cid) + `,"body_revision":` + u(bodyRevision) + `,"anchor_history_body_revision":` + anchorRevision + `,"parent":` + historyNullableRaw(parent) + `,"parent_history_available":` + strconv.FormatBool(archived.ParentHistory) + `,"deleted":` + strconv.FormatBool(deleted) + `,"hidden":` + strconv.FormatBool(hidden) + `,"resolved":` + strconv.FormatBool(resolved) + `}`
}
func historyCommentChange(n *note, c *comment, action string) {
	if !public(n.Mode) || c.Encrypted {
		return
	}
	key := commentKey(n.ID, c.ID)
	value, exists := historyComments.Get(key)
	var archived *historyComment
	if action == "comment-add" {
		if exists {
			panic("notes: comment history collision")
		}
		h := n.History
		if h == nil {
			panic("notes: missing public history")
		}
		// Every body revision since publication is recorded, so the anchored
		// version is in public history exactly when it is not older than that.
		anchor := c.BodyRevision >= h.StartBodyRevision
		_, parent := historyComments.Get(commentKey(n.ID, c.Parent))
		// Anchor and Body share the comment's arrays for the same single-copy reason.
		archived = &historyComment{Parent: rawID(c.Parent), Author: c.Author, BodyRevision: c.BodyRevision, Epoch: c.Epoch, CreatedHeight: c.CreatedHeight,
			Anchor: c.Anchor, Body: c.Body, AnchorHistory: anchor, ParentHistory: parent}
		historyComments.Set(key, archived)
	} else {
		if !exists {
			panic("notes: missing public comment history")
		}
		archived = value.(*historyComment)
	}
	e := historyAppend(n, c.Last.Actor, c.Last.Operation, c.ID, action, historyCommentDetail(idText(c.ID), rawID(c.Parent), c.Revision, c.BodyRevision, c.Deleted, c.Hidden, c.Resolved, archived))
	archived.LatestSeq, archived.Deleted, archived.Hidden, archived.Resolved = e.Seq, c.Deleted, c.Hidden, c.Resolved
}
func historyCleanup(n *note, who address, counts [5]int) {
	if !public(n.Mode) {
		return
	}
	total := counts[0] + counts[1] + counts[2] + counts[3] + counts[4]
	if total == 0 {
		return
	}
	detail := `{"comment_index":` + u(uint64(counts[0])) + `,"comments":` + u(uint64(counts[1])) + `,"cooldowns":` + u(uint64(counts[2])) + `,"epochs":` + u(uint64(counts[3])) + `,"requests":` + u(uint64(counts[4])) + `,"total":` + u(uint64(total)) + `}`
	historyAppend(n, who, [16]byte{}, [16]byte{}, "cleanup", detail)
}
