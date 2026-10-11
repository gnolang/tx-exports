package memba_notes_v1

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
type historyVersion struct {
	State        note
	Seq          uint64
	Title, Body  *historyBlob
	PublicWrites bool
}
type historyInfo struct {
	StartRevision, StartBodyRevision, Head uint64
	Latest                                 *historyVersion
}
type historyEntry struct {
	Seq, Revision, Proposal          uint64
	Height                           int64
	Actor, Executor                  address
	Operation, Comment               [16]byte
	Action, GovernanceAction, Detail string
}
type historyComment struct {
	Initial                      comment
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

var historyInfos = avl.NewTree()
var historyVersions = avl.NewTree()
var historyBlobs = avl.NewTree()
var historyEntries = avl.NewTree()
var historyComments = avl.NewTree()

// Only GovApply sets this while the existing busy guard excludes reentry.
var historyGov *historyCall

func historyKey(id [16]byte, revision uint64) string {
	s := strconv.FormatUint(revision, 10)
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
	v, ok := historyInfos.Get(idText(id))
	if !ok {
		return nil
	}
	return v.(*historyInfo)
}
func historyInsert(tree *avl.Tree, key string, value interface{}) {
	if _, exists := tree.Get(key); exists {
		panic("notes: history collision")
	}
	tree.Set(key, value)
}
func historyField(n *note, field string, revision uint64, data []byte) *historyBlob {
	key := field + ":" + historyKey(n.ID, revision)
	hash := sha256.Sum256(data)
	b := &historyBlob{Bytes: data, Hash: hex.EncodeToString(hash[:])}
	historyInsert(historyBlobs, key, b)
	return b
}
func historyAppend(n *note, who address, op, cid [16]byte, action, detail string) *historyEntry {
	h := historyGet(n.ID)
	if h == nil || h.Head == ^uint64(0) {
		panic("notes: history unavailable/exhausted")
	}
	h.Head++
	e := &historyEntry{Seq: h.Head, Revision: n.Revision, Height: runtime.ChainHeight(), Actor: who, Operation: op, Comment: cid, Action: action, Detail: detail}
	if historyGov != nil {
		e.Executor, e.Proposal, e.GovernanceAction = historyGov.Executor, historyGov.Proposal, historyGov.Action
		e.Operation = historyGov.Operation
	}
	historyInsert(historyEntries, historyKey(n.ID, e.Seq), e)
	return e
}
func historyNote(n *note, who address, op [16]byte, action, extra string) {
	if !public(n.Mode) {
		return
	}
	h := historyGet(n.ID)
	if h == nil {
		if action != "create" && action != "publish" {
			panic("notes: missing public history")
		}
		h = &historyInfo{StartRevision: n.Revision, StartBodyRevision: n.BodyRevision}
		historyInsert(historyInfos, idText(n.ID), h)
	}
	previous := "null"
	mask := 0
	if h.Latest != nil {
		previous = u(h.Latest.State.Revision)
		if n.TitleRevision != h.Latest.State.TitleRevision {
			mask |= 1
		}
		if n.BodyRevision != h.Latest.State.BodyRevision {
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
	v := &historyVersion{State: *n, Seq: e.Seq, PublicWrites: publicWritesEnabled(n)}
	// The snapshot never owns current mutable content, private manifests or readers.
	v.State.Title, v.State.Body, v.State.Commitment, v.State.Readers = nil, nil, nil, nil
	v.State.Writers = copiedAddresses(n.Writers)
	if !n.Deleted {
		if h.Latest != nil && h.Latest.State.TitleRevision == n.TitleRevision {
			v.Title = h.Latest.Title
		} else {
			v.Title = historyField(n, "title", n.TitleRevision, n.Title)
		}
		if h.Latest != nil && h.Latest.State.BodyRevision == n.BodyRevision {
			v.Body = h.Latest.Body
		} else {
			v.Body = historyField(n, "body", n.BodyRevision, n.Body)
		}
	}
	historyInsert(historyVersions, historyKey(n.ID, n.Revision), v)
	h.Latest = v
}
func historyNullableID(id [16]byte) string {
	if id == ([16]byte{}) {
		return "null"
	}
	return q(idText(id))
}
func historyNullableText(s string) string {
	if s == "" {
		return "null"
	}
	return q(s)
}
func historyCommentDetail(c *comment, archived *historyComment) string {
	anchorRevision := "null"
	if archived.AnchorHistory {
		anchorRevision = u(c.BodyRevision)
	}
	return `{"comment_id":` + q(idText(c.ID)) + `,"comment_revision":` + u(c.Revision) + `,"content_ref":` + q(idText(c.ID)) + `,"body_revision":` + u(c.BodyRevision) + `,"anchor_history_body_revision":` + anchorRevision + `,"parent":` + historyNullableID(c.Parent) + `,"parent_history_available":` + strconv.FormatBool(archived.ParentHistory) + `,"deleted":` + strconv.FormatBool(c.Deleted) + `,"hidden":` + strconv.FormatBool(c.Hidden) + `,"resolved":` + strconv.FormatBool(c.Resolved) + `}`
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
		_, anchor := historyBlobs.Get("body:" + historyKey(n.ID, c.BodyRevision))
		_, parent := historyComments.Get(commentKey(n.ID, c.Parent))
		// Initial shares the comment's arrays for the same single-copy reason.
		archived = &historyComment{Initial: *c, AnchorHistory: anchor, ParentHistory: parent}
		historyInsert(historyComments, key, archived)
	} else {
		if !exists {
			panic("notes: missing public comment history")
		}
		archived = value.(*historyComment)
	}
	e := historyAppend(n, c.Last.Actor, c.Last.Operation, c.ID, action, historyCommentDetail(c, archived))
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
