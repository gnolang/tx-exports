package memba_notes_rc1

import (
	"chain/runtime"
	"gno.land/p/samcrew/avl"
	"strconv"
	"strings"
	"unicode/utf8"
)

const MaxCommentBytes = 4000
const MaxAnchorBytes = 600
const CommentCooldownBlocks int64 = 10
const MaxCommentPage = 5

type comment struct {
	Sequence                  uint64
	ID, Parent                [16]byte
	Author                    address
	BodyRevision              uint64
	Epoch                     uint32
	Anchor, Body              []byte
	Revision                  uint64
	CreatedHeight             int64
	Last                      receipt
	Deleted, Hidden, Resolved bool
	Encrypted                 bool
}

var comments = avl.NewTree()
var commentIndex = avl.NewTree()
var cooldowns = avl.NewTree()

func commentKey(id, cid [16]byte) string { return idText(id) + ":" + idText(cid) }
func getComment(id, cid [16]byte) *comment {
	v, ok := comments.Get(commentKey(id, cid))
	if !ok {
		panic("notes: comment missing")
	}
	return v.(*comment)
}
func commentExpected(c *comment, rev uint64, op [16]byte) {
	if c.Revision != rev || rev == ^uint64(0) {
		panic("notes: stale comment revision")
	}
	if op == ([16]byte{}) || c.Last.Operation == op {
		panic("notes: invalid comment operation")
	}
}
func commentReceipt(c *comment, who address, op [16]byte) {
	c.Revision++
	c.Last = receipt{op, who, runtime.ChainHeight()}
}
func mayComment(cur realm, n *note, who address) bool {
	if n.Mode == ModePublicOpen {
		return true
	}
	if n.Mode == ModePublic {
		return who == n.Owner || writer(n, who) || n.GovWriters && n.Owner == govAddress && govMember(who) || policyAllows(cur, n, who, OpComment)
	}
	if n.Mode == ModeShared {
		return contains(n.Readers, who)
	}
	return false
}

// Public comments carry UTF8 anchor/body separately. Encrypted comments will
// carry their combined authenticated payload in Body and an empty Anchor.
func AddComment(cur realm, id, cid [16]byte, bodyRevision uint64, epoch uint32, parent [16]byte, anchor, body []byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	n := live(id)
	if paused {
		panic("notes: comments paused")
	}
	if !mayComment(cur, n, who) {
		panic("notes: comments denied")
	}
	if cid == ([16]byte{}) || opID == ([16]byte{}) {
		panic("notes: empty comment id")
	}
	if _, ok := comments.Get(commentKey(id, cid)); ok {
		panic("notes: comment id used")
	}
	if bodyRevision == 0 || bodyRevision > n.BodyRevision || epoch != n.Epoch {
		panic("notes: bad comment anchor version")
	}
	if public(n.Mode) && (len(anchor) > MaxAnchorBytes || !utf8.Valid(anchor) || len(body) == 0 || len(body) > MaxCommentBytes || !utf8.Valid(body) || utf8.RuneCount(body) > 1000) {
		panic("notes: invalid comment payload")
	}
	privateWritable(n)
	if encrypted(n.Mode) {
		if len(anchor) != 0 {
			panic("notes: encrypted anchor must be inside payload")
		}
		validateCipher(body, n.Epoch, 3, 1, MaxCipherCommentBytes)
	}
	if parent != ([16]byte{}) {
		p := getComment(id, parent)
		if p.Deleted {
			panic("notes: parent deleted")
		}
	}
	ck := idText(id) + ":" + string(who)
	h := runtime.ChainHeight()
	if v, ok := cooldowns.Get(ck); ok && h-v.(int64) < CommentCooldownBlocks {
		panic("notes: comment cooldown")
	}
	if n.CommentSequence == ^uint64(0) {
		panic("notes: comment sequence exhausted")
	}
	n.CommentSequence++
	c := &comment{Sequence: n.CommentSequence, Encrypted: encrypted(n.Mode), ID: cid, Parent: parent, Author: who, BodyRevision: bodyRevision, Epoch: epoch, Anchor: copied(anchor), Body: copied(body), CreatedHeight: h}
	commentReceipt(c, who, opID)
	comments.Set(commentKey(id, cid), c)
	seq := strconv.FormatUint(c.Sequence, 10)
	commentIndex.Set(idText(id)+":"+strings.Repeat("0", 20-len(seq))+seq+":"+idText(cid), commentKey(id, cid))
	cooldowns.Set(ck, h)
	historyCommentChange(n, c, "comment-add")
}
func DeleteComment(cur realm, id, cid [16]byte, baseRevision uint64, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	// Authors can clear their current payload even after the note is deleted or
	// paused. Public history keeps the original unless a moderator redacts it.
	n := find(id)
	c := getComment(id, cid)
	if c.Author != who {
		panic("notes: comment author required")
	}
	if c.Deleted {
		panic("notes: comment deleted")
	}
	commentExpected(c, baseRevision, opID)
	c.Deleted = true
	c.Anchor = nil
	c.Body = nil
	commentReceipt(c, who, opID)
	historyCommentChange(n, c, "comment-delete")
}
func ResolveComment(cur realm, id, cid [16]byte, baseRevision uint64, resolved bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateResolveComment(cur, who, id, cid, baseRevision, resolved, opID)
}
func mutateResolveComment(cur realm, who address, id, cid [16]byte, baseRevision uint64, resolved bool, opID [16]byte) {
	n := live(id)
	requireWrite(cur, n, who)
	c := getComment(id, cid)
	commentExpected(c, baseRevision, opID)
	c.Resolved = resolved
	commentReceipt(c, who, opID)
	historyCommentChange(n, c, "comment-resolution")
}
func HideComment(cur realm, id, cid [16]byte, baseRevision uint64, hidden bool, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateHideComment(cur, who, id, cid, baseRevision, hidden, opID)
}
func mutateHideComment(cur realm, who address, id, cid [16]byte, baseRevision uint64, hidden bool, opID [16]byte) {
	n := live(id)
	if who != n.Owner && !moderator(who) {
		panic("notes: owner required or moderator")
	}
	c := getComment(id, cid)
	commentExpected(c, baseRevision, opID)
	if v, ok := historyComments.Get(commentKey(id, cid)); ok && !hidden && v.(*historyComment).Redacted {
		panic("notes: comment redacted")
	}
	c.Hidden = hidden
	commentReceipt(c, who, opID)
	historyCommentChange(n, c, "comment-visibility")
}
func commentJSON(c *comment) string {
	return `{"id":` + q(idText(c.ID)) + `,"parent":` + q(idText(c.Parent)) + `,"author":` + q(string(c.Author)) + `,"encrypted":` + strconv.FormatBool(c.Encrypted) + `,"body_revision":` + u(c.BodyRevision) + `,"epoch":` + u(uint64(c.Epoch)) + `,"revision":` + u(c.Revision) + `,"anchor_blob":` + blob(c.Anchor) + `,"body_blob":` + blob(c.Body) + `,"created_height":` + q(strconv.FormatInt(c.CreatedHeight, 10)) + `,"op_id":` + q(idText(c.Last.Operation)) + `,"actor":` + q(string(c.Last.Actor)) + `,"height":` + q(strconv.FormatInt(c.Last.Height, 10)) + `,"deleted":` + strconv.FormatBool(c.Deleted) + `,"hidden":` + strconv.FormatBool(c.Hidden) + `,"resolved":` + strconv.FormatBool(c.Resolved) + `}`
}
func CommentJSON(idHex, cidHex string) string {
	v, ok := comments.Get(commentKey(readID(idHex), readID(cidHex)))
	if !ok {
		return "null"
	}
	return commentJSON(v.(*comment))
}

// Comments paginate in append order; editing or moderation never reorders them.
func CommentsJSON(idHex, cursor string, limit int) string {
	id := readID(idHex)
	find(id)
	if limit < 1 || limit > MaxCommentPage {
		panic("notes: page limit")
	}
	if cursor != "" {
		if len(cursor) != 53 || cursor[20] != ':' {
			panic("notes: bad cursor")
		}
		readID(cursor[21:])
		for _, c := range cursor[:20] {
			if c < '0' || c > '9' {
				panic("notes: bad cursor")
			}
		}
	}
	prefix := idText(id) + ":"
	start := prefix + cursor
	items := []string{}
	next := ""
	commentIndex.Iterate(start, prefix+"\xff", func(k string, v interface{}) bool {
		if cursor != "" && k == start {
			return false
		}
		cv, ok := comments.Get(v.(string))
		if !ok {
			panic("notes: corrupt comment index")
		}
		items = append(items, commentJSON(cv.(*comment)))
		next = strings.TrimPrefix(k, prefix)
		return len(items) == limit
	})
	if len(items) < limit {
		next = ""
	}
	return `{"items":[` + strings.Join(items, ",") + `],"next_cursor":` + q(next) + `}`
}

// Purge never operates on a live note. Each call erases at most limit records
// (including cooldowns); a permanent note tombstone prevents ID reuse.
func Purge(cur realm, id [16]byte, limit int) int {
	who := enter(cur, false)
	defer leave()
	return mutatePurge(cur, who, id, limit)
}
func mutatePurge(cur realm, who address, id [16]byte, limit int) int {
	n := find(id)
	owner(n, who)
	if !n.Deleted {
		panic("notes: delete before purge")
	}
	if limit < 1 || limit > MaxPage {
		panic("notes: purge limit")
	}
	counts := [5]int{}
	counts[0] = purgePrefix(commentIndex, idText(id)+":", limit)
	counts[1] = purgePrefix(comments, idText(id)+":", limit-counts[0])
	counts[2] = purgePrefix(cooldowns, idText(id)+":", limit-counts[0]-counts[1])
	counts[3] = purgePrefix(epochs, idText(id)+":", limit-counts[0]-counts[1]-counts[2])
	counts[4] = purgeRequests(n, limit-counts[0]-counts[1]-counts[2]-counts[3])
	historyCleanup(n, who, counts)
	return counts[0]+counts[1]+counts[2]+counts[3]+counts[4]
}
func purgePrefix(tree *avl.Tree, prefix string, limit int) int {
	if limit == 0 {
		return 0
	}
	doomed := []string{}
	tree.Iterate(prefix, prefix+"\xff", func(k string, v interface{}) bool { doomed = append(doomed, k); return len(doomed) == limit })
	for _, k := range doomed {
		tree.Remove(k)
	}
	return len(doomed)
}
