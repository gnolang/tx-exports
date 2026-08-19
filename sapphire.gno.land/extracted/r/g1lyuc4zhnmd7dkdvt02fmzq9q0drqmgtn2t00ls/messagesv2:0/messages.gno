// Package messages implements "Onchain Messages" — a public, fully
// threaded on-chain guestbook. Anyone posts a message to a shared public
// board; anyone can reply to any message, arbitrarily deep. There is no
// recipient/target field — this is a public wall, not private messaging
// (gno.land has no encryption anyway, so a "to" field would only ever be
// a label, never real privacy). Any address can look up every direct
// reply to everything IT has authored — its "inbox" — computed
// incrementally at Post-time (see inboxByAuthor below), never joined
// from messages+repliesByParent at read time, so an inbox lookup stays
// cheap regardless of how many messages or replies someone has
// accumulated.
//
// Design mirrors this project's existing nftminter.gno realm (Gems)
// throughout: pipe-delimited/base64 summary lines, page-based pagination
// windowing that returns "" past the last page rather than clamping
// (Gems' own CollectionSummary already behaves this way — the clamping
// Gems does elsewhere is Render()'s own human-gnoweb-browsing
// convenience, a separate concern this realm doesn't need for v1), and
// the same avl.Tree/seqid.ID/callerAddress() plumbing.
//
// Deploy identity: g1lyuc4zhnmd7dkdvt02fmzq9q0drqmgtn2t00ls -- both this
// package and its sibling gno.land/p/<addr>/avl declare their module path
// under that address. See DEPLOY.md in this folder for the deploy
// checklist itself.
package messagesv2

import (
	"encoding/base64"
	"errors"
	"strconv"
	"strings"

	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/g1lyuc4zhnmd7dkdvt02fmzq9q0drqmgtn2t00ls/avl"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"

	// oldmessages is the immediate predecessor realm this package migrates
	// data FROM (see MigrateFrom below). gno.land import paths are static,
	// so a future v3 migrating from this v2 will hardcode ITS OWN
	// predecessor import the same way -- each version only ever knows how
	// to import the one version directly before it.
	oldmessages "gno.land/r/g1lyuc4zhnmd7dkdvt02fmzq9q0drqmgtn2t00ls/messages"
)

const (
	// MaxMessageLen caps a single message's text. Storage-deposit cost
	// scales with data size, and this board has no moderation/edit path,
	// so a hard cap keeps a single bad post cheap to store and cheap for
	// every downstream page (feed/replies/inbox) to render. 1000 chars is
	// long enough for a real paragraph, short enough that a page of
	// pageSize messages stays small.
	MaxMessageLen = 1000

	// pageSize is how many rows FeedSummary/RepliesSummary/InboxSummary
	// return per call. Text-only storage here is far cheaper per row
	// than Gems' on-the-fly SVG generation (see nftminter.gno's own
	// homeRenderLimit doc comment for why THAT constant had to be tuned
	// down from 50 to 10), so one shared constant across all three lists
	// is enough for v1.
	pageSize = 20

	// maxParentChainDepth bounds ParentChainSummary's walk-to-root.
	// Threads nest arbitrarily deep by design (fully threaded replies),
	// so an unbounded walk here would reintroduce the exact "unbounded
	// on-chain work" trap Gems' own CollectionSummary hit before it was
	// paginated — this is a defensive ceiling, not an expected real depth.
	maxParentChainDepth = 100
)

// Message is one post — top-level or a reply, no structural difference
// between the two beyond ParentID.
type Message struct {
	ID            uint64
	Author        address
	Text          string
	ParentID      uint64 // 0 = top-level; never a real message's own ID (see Post)
	CreatedHeight int64
	ReplyCount    int64 // direct replies only, kept in sync at Post-time
	Edited        bool  // true once Edit has been called on this message at least once
}

var (
	// nextID assigns message IDs. Post calls Next() FIRST and uses the
	// already-advanced value (unlike nftminter.gno's own nextID, read
	// BEFORE Next() advances it) — deliberately, so ID 0 stays
	// permanently unassigned and can serve as ParentID's "no parent /
	// top-level" sentinel without ever colliding with a real message.
	nextID seqid.ID

	// messages holds every message ever posted, top-level and replies
	// alike, keyed by its own ID.
	messages avl.Tree // seqid.ID(id).String() -> Message

	// topLevelIDs is every top-level (ParentID==0) message ID, oldest
	// first — same shape as nftminter.gno's mintedIDs. FeedSummary walks
	// this backward for newest-first pagination.
	topLevelIDs []uint64

	// repliesByParent indexes each message's own direct replies in post
	// order. The local index is read from the parent's OWN ReplyCount
	// field right before Post increments it — a 0-based position among
	// that parent's replies specifically, not a global ID. RepliesSummary
	// does a direct windowed Get() per row against this, no scanning.
	repliesByParent avl.Tree // parentID.String()+":"+seqid.ID(localIdx).String() -> uint64 (childID)

	// inboxCountByAuthor / inboxByAuthor together are the actual "my
	// inbox" index — same windowed shape as repliesByParent, but
	// bucketed by the REPLIED-TO message's OWN author, not by the
	// specific parent message. Populated incrementally inside Post by
	// looking up the parent's Author once, at write time — InboxSummary
	// never joins messages+repliesByParent at read time.
	inboxCountByAuthor avl.Tree // author.String() -> int64
	inboxByAuthor       avl.Tree // author.String()+":"+seqid.ID(localIdx).String() -> uint64 (replyID)

	// migrated latches once MigrateFrom has run, so it can only ever
	// replay the predecessor realm's data one time -- calling it twice
	// would double-append every migrated message into topLevelIDs/
	// repliesByParent/inboxByAuthor.
	migrated bool
)

// adminAddress is this realm's own deploy identity -- the only caller
// allowed to run MigrateFrom. Not a security boundary against a
// malicious admin (there isn't one here; it's the same wallet that
// deployed both this and the predecessor realm), just a guard against
// a stray/duplicate call from anyone else.
var adminAddress = address("g1lyuc4zhnmd7dkdvt02fmzq9q0drqmgtn2t00ls")

// callerAddress derives the address that crossed into this realm, same
// one-line helper nftminter.gno itself uses (see that file's own doc
// comment on why unsaferealm.PreviousRealm() rather than cur.Previous()).
func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func getMessage(id uint64) (Message, bool) {
	raw := messages.Get(seqid.ID(id).String())
	msg, ok := raw.(Message)
	return msg, ok
}

// messageSummaryLine mirrors nftminter.gno's own TokenSummary shape:
// pipe-delimited fields, only the free-text field base64-encoded. Edited
// is appended as a 7th field (rather than inserted earlier) so it stays
// backward-compatible with any caller still splitting the original
// 6-field layout and only reading fields by fixed index up to 5.
func messageSummaryLine(msg Message) string {
	edited := "0"
	if msg.Edited {
		edited = "1"
	}
	fields := []string{
		ufmt.Sprintf("%d", msg.ID),
		msg.Author.String(),
		ufmt.Sprintf("%d", msg.ParentID),
		ufmt.Sprintf("%d", msg.CreatedHeight),
		ufmt.Sprintf("%d", msg.ReplyCount),
		base64.StdEncoding.EncodeToString([]byte(msg.Text)),
		edited,
	}
	return strings.Join(fields, "|")
}

// parseMessageSummaryLine reverses messageSummaryLine, used only by
// MigrateFrom to replay the predecessor realm's own summary output back
// into a Message. The predecessor's lines are always the original
// 6-field layout (it never had an Edited field), so a migrated message
// always starts with Edited == false -- there is no lossy history to
// recover, since the source realm never tracked edits either.
func parseMessageSummaryLine(line string) Message {
	parts := strings.Split(line, "|")
	if len(parts) < 6 {
		panic("malformed source message line: " + line)
	}
	id, err := strconv.ParseUint(parts[0], 10, 64)
	if err != nil {
		panic("malformed source message id: " + parts[0])
	}
	parentID, err := strconv.ParseUint(parts[2], 10, 64)
	if err != nil {
		panic("malformed source message parentID: " + parts[2])
	}
	createdHeight, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		panic("malformed source message createdHeight: " + parts[3])
	}
	replyCount, err := strconv.ParseInt(parts[4], 10, 64)
	if err != nil {
		panic("malformed source message replyCount: " + parts[4])
	}
	textBytes, err := base64.StdEncoding.DecodeString(parts[5])
	if err != nil {
		panic("malformed source message text encoding")
	}
	return Message{
		ID:            id,
		Author:        address(parts[1]),
		Text:          string(textBytes),
		ParentID:      parentID,
		CreatedHeight: createdHeight,
		ReplyCount:    replyCount,
	}
}

// Post creates a new message. parentID == 0 means a top-level post;
// any other value must name an existing message, and the new message
// becomes a direct reply to it — arbitrarily deep threading is just
// replies-to-replies, no special casing needed beyond this.
func Post(cur realm, text string, parentID uint64) uint64 {
	if len(text) == 0 {
		panic("message text cannot be empty")
	}
	if len(text) > MaxMessageLen {
		panic(ufmt.Sprintf("message exceeds the %d-character limit", MaxMessageLen))
	}

	var parentAuthor address
	var parentKey string
	var localReplyIdx int64
	if parentID != 0 {
		parentKey = seqid.ID(parentID).String()
		raw := messages.Get(parentKey)
		parent, ok := raw.(Message)
		if !ok {
			panic(ufmt.Sprintf("parent message %d does not exist", parentID))
		}
		parentAuthor = parent.Author
		localReplyIdx = parent.ReplyCount
		parent.ReplyCount++
		messages.Set(parentKey, parent)
	}

	id := uint64(nextID.Next()) // advance-first: see nextID's own doc comment above
	msg := Message{
		ID:            id,
		Author:        callerAddress(),
		Text:          text,
		ParentID:      parentID,
		CreatedHeight: runtime.ChainHeight(),
	}
	messages.Set(seqid.ID(id).String(), msg)

	if parentID == 0 {
		topLevelIDs = append(topLevelIDs, id)
	} else {
		repliesByParent.Set(parentKey+":"+seqid.ID(uint64(localReplyIdx)).String(), id)

		inboxIdx, _ := inboxCountByAuthor.Get(parentAuthor.String()).(int64)
		inboxByAuthor.Set(parentAuthor.String()+":"+seqid.ID(uint64(inboxIdx)).String(), id)
		inboxCountByAuthor.Set(parentAuthor.String(), inboxIdx+1)
	}
	return id
}

// Edit overwrites msgID's own text in place, author-only. Thread
// position, ID, ParentID, ReplyCount, and CreatedHeight are untouched --
// only Text changes, and Edited latches true permanently (never reset),
// so readers can always tell a message was changed after its original
// CreatedHeight even across repeated edits.
func Edit(cur realm, id uint64, newText string) {
	if len(newText) == 0 {
		panic("message text cannot be empty")
	}
	if len(newText) > MaxMessageLen {
		panic(ufmt.Sprintf("message exceeds the %d-character limit", MaxMessageLen))
	}
	msg, ok := getMessage(id)
	if !ok {
		panic(ufmt.Sprintf("message %d does not exist", id))
	}
	if msg.Author != callerAddress() {
		panic("only the original author can edit this message")
	}
	msg.Text = newText
	msg.Edited = true
	messages.Set(seqid.ID(id).String(), msg)
}

// MessageCount is every message ever posted, top-level and replies alike.
func MessageCount() int64 {
	return int64(messages.Size())
}

// FeedCount is how many top-level messages exist — what FeedSummary
// paginates over.
func FeedCount() int64 {
	return int64(len(topLevelIDs))
}

// FeedSummary returns page's worth of top-level messages, newest-first.
// page < 1 clamps to 1; a page past the end returns "" (not clamped to
// the last real page — see this file's own top doc comment on why).
func FeedSummary(page int) string {
	total := len(topLevelIDs)
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * pageSize
	endK := startK + pageSize
	if endK > total {
		endK = total
	}
	var lines []string
	for k := startK; k < endK; k++ {
		id := topLevelIDs[total-1-k] // k=0 is newest
		msg, ok := getMessage(id)
		if !ok {
			continue
		}
		lines = append(lines, messageSummaryLine(msg))
	}
	return strings.Join(lines, "\n")
}

// ReplyCount is how many DIRECT replies msgID has.
func ReplyCount(msgID uint64) int64 {
	msg, ok := getMessage(msgID)
	if !ok {
		return 0
	}
	return msg.ReplyCount
}

// RepliesSummary returns page's worth of msgID's DIRECT replies,
// oldest-first (a conversation reads top-to-bottom) — cheaper than
// FeedSummary's own newest-first walk, since repliesByParent's local
// index is already assigned in post order, so this is a direct forward
// windowed Get() with no reversal arithmetic.
func RepliesSummary(msgID uint64, page int) string {
	parent, ok := getMessage(msgID)
	if !ok {
		return ""
	}
	total := int(parent.ReplyCount)
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * pageSize
	endK := startK + pageSize
	if endK > total {
		endK = total
	}
	parentKey := seqid.ID(msgID).String()
	var lines []string
	for k := startK; k < endK; k++ {
		raw := repliesByParent.Get(parentKey + ":" + seqid.ID(uint64(k)).String())
		childID, ok := raw.(uint64)
		if !ok {
			continue
		}
		child, ok := getMessage(childID)
		if !ok {
			continue
		}
		lines = append(lines, messageSummaryLine(child))
	}
	return strings.Join(lines, "\n")
}

// MessageSummary is one message's own detail line (for a permalink/
// thread view showing a single node in isolation).
func MessageSummary(msgID uint64) (string, error) {
	msg, ok := getMessage(msgID)
	if !ok {
		return "", errors.New(ufmt.Sprintf("message %d does not exist", msgID))
	}
	return messageSummaryLine(msg), nil
}

// ParentChainSummary returns msgID's ancestor chain, oldest-ancestor-
// first — e.g. for a grandchild reply, [top-level, its reply]. Empty if
// msgID doesn't exist or is itself top-level. Bounded by
// maxParentChainDepth (see that const's own doc comment).
func ParentChainSummary(msgID uint64) string {
	msg, ok := getMessage(msgID)
	if !ok {
		return ""
	}
	var lines []string
	cur := msg
	depth := 0
	for cur.ParentID != 0 && depth < maxParentChainDepth {
		parent, ok := getMessage(cur.ParentID)
		if !ok {
			break
		}
		lines = append(lines, messageSummaryLine(parent))
		cur = parent
		depth++
	}
	// lines is currently immediate-parent-first (youngest ancestor
	// first) — reverse for the documented oldest-ancestor-first order.
	for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
		lines[i], lines[j] = lines[j], lines[i]
	}
	return strings.Join(lines, "\n")
}

// InboxCount is how many replies exist across every message owner has
// ever authored.
func InboxCount(owner address) int64 {
	raw := inboxCountByAuthor.Get(owner.String())
	n, ok := raw.(int64)
	if !ok {
		return 0
	}
	return n
}

// InboxSummary returns page's worth of replies to everything owner has
// authored, newest-first — the "my inbox" view. Uses the same
// newest-first reversal as FeedSummary, against inboxByAuthor's own
// append-order local index (see that var's own doc comment).
func InboxSummary(owner address, page int) string {
	total := int(InboxCount(owner))
	if page < 1 {
		page = 1
	}
	startK := (page - 1) * pageSize
	endK := startK + pageSize
	if endK > total {
		endK = total
	}
	ownerKey := owner.String()
	var lines []string
	for k := startK; k < endK; k++ {
		localIdx := total - 1 - k // k=0 is newest
		raw := inboxByAuthor.Get(ownerKey + ":" + seqid.ID(uint64(localIdx)).String())
		replyID, ok := raw.(uint64)
		if !ok {
			continue
		}
		reply, ok := getMessage(replyID)
		if !ok {
			continue
		}
		lines = append(lines, messageSummaryLine(reply))
	}
	return strings.Join(lines, "\n")
}

// insertMigratedMessage replays one already-existing message into this
// package's own storage, reconstructing the same bookkeeping Post()
// would have produced -- EXCEPT it never increments a parent's
// ReplyCount (msg.ReplyCount already carries its final value straight
// from the source realm's own line) and it takes the reply's local
// index from replyLocalIdx rather than reading+incrementing the
// parent's live field, since parent.ReplyCount here is already final,
// not a running counter.
//
// Correctness depends on the caller replaying messages in ascending ID
// order (== original post order, since IDs are assigned sequentially
// and never reused) so a reply is always processed after its own
// parent, and so per-parent/per-author local indices come out in the
// same order the original repliesByParent/inboxByAuthor entries did.
func insertMigratedMessage(msg Message, replyLocalIdx map[uint64]int64) {
	messages.Set(seqid.ID(msg.ID).String(), msg)

	if msg.ParentID == 0 {
		topLevelIDs = append(topLevelIDs, msg.ID)
		return
	}

	parentKey := seqid.ID(msg.ParentID).String()
	raw := messages.Get(parentKey)
	parent, ok := raw.(Message)
	if !ok {
		// Parent wasn't migrated -- can't happen when replaying in
		// ascending ID order against a source realm with no deletions,
		// but skip rather than panic so one bad row doesn't abort the
		// whole migration.
		return
	}

	localIdx := replyLocalIdx[msg.ParentID]
	repliesByParent.Set(parentKey+":"+seqid.ID(uint64(localIdx)).String(), msg.ID)
	replyLocalIdx[msg.ParentID] = localIdx + 1

	inboxIdx, _ := inboxCountByAuthor.Get(parent.Author.String()).(int64)
	inboxByAuthor.Set(parent.Author.String()+":"+seqid.ID(uint64(inboxIdx)).String(), msg.ID)
	inboxCountByAuthor.Set(parent.Author.String(), inboxIdx+1)
}

// MigrateFrom replays every message from the predecessor realm
// (oldmessages, imported above) into this package, preserving original
// IDs, authorship, thread structure (ParentID/ReplyCount), and
// CreatedHeight. Callable exactly once (see the migrated latch), by the
// deploy address only. Text and structure copy verbatim; the migrated
// Edited flag always starts false (see parseMessageSummaryLine's own
// doc comment).
//
// After migration, nextID is advanced so the very next real Post() call
// continues after the migrated ID range instead of colliding with it.
//
// This assumes the source realm's own MessageCount() equals its highest
// assigned ID -- true as long as it never deletes messages, which
// neither this package nor its predecessor does.
func MigrateFrom(cur realm) int64 {
	if migrated {
		panic("already migrated")
	}
	if callerAddress() != adminAddress {
		panic("only the deploy address can run MigrateFrom")
	}
	migrated = true

	total := uint64(oldmessages.MessageCount())
	replyLocalIdx := make(map[uint64]int64)
	var maxID uint64
	for id := uint64(1); id <= total; id++ {
		line, err := oldmessages.MessageSummary(id)
		if err != nil {
			continue
		}
		msg := parseMessageSummaryLine(line)
		insertMigratedMessage(msg, replyLocalIdx)
		if msg.ID > maxID {
			maxID = msg.ID
		}
	}
	nextID = seqid.ID(maxID)
	return int64(maxID)
}
