package memba_feed_v1

// memba_feed_v1 — Global social feed realm for Memba (W7.2 P0).
//
// OPEN-WRITE: any wallet may post. This inverts every assumption of the
// DAO-scoped memba_dao_channels_v2 (members-only, 20 channels / 500 threads),
// so the realm is NEW — what is ported VERBATIM from channels_v2 is its
// hardening discipline:
//
//   B1 render-DoS bounds — reads NEVER iterate the monotonic nextPostID.
//     Live (visible) posts are tracked in dedicated AVL indexes and every
//     read path is paginated to a fixed window. channels_v2 used []uint64
//     slices (safe under its 500-per-channel cap); an open feed is unbounded,
//     so the live indexes here are composite-key AVL trees instead —
//     O(log n) insert/remove, O(page) scan, no single node that grows forever.
//   B2 state-shrink — author deletes soft-delete + enqueue a tombstone;
//     SweepTombstones hard-removes nodes (bounded, permissionless GC).
//   B3 pause policy — every user-facing write is blocked while paused;
//     owner/moderation stays operational (no funds in this realm).
//   Flag pipeline — one flag per address per post, threshold auto-hide.
//     Open write invites brigading, so the threshold is higher than
//     channels_v2's 3 and flagging is further gated by account age and a
//     per-day flag budget.
//
// Anti-spam (open write has no membership gate to lean on):
//   - per-address block cooldown between posts, stricter for accounts first
//     seen fewer than YoungAccountBlocks ago;
//   - body length cap; media CID count cap (CIDs stored on-chain only —
//     pinning/serving is the backend's PinMedia pipeline, P2).
//
// Reads: exported *JSON funcs via RPC vm/qeval — cursor-paginated, O(limit)
// at any depth (the app reads from the indexer; these are the fallback).
// Render() is the human gnoweb view: bounded pages with a hard depth cap
// (MaxRenderPage) — deep history belongs to the cursor API, not qrender.
//
// Moderation P0: realm owner only (ModRemovePost / UnhidePost / BanAuthor is
// W8.2's moderation board via a daokit moderator role — p/samcrew/modboard).
// Every moderation action emits for public audit.
//
// This realm holds NO funds: no banker, no OriginSend, no fee lane. A future
// tipping lane is a separate SAFETY_GATED flag + fee-spine lane "feed".

import (
	"strconv"
	"strings"

	"gno.land/p/samcrew/avl"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
)

// ── Constants ────────────────────────────────────────────────

const (
	MaxBodyLen   = 1000 // post body (roadmap 4.1)
	MaxMediaCIDs = 4    // stored per post; pin/serve pipeline is P2
	MaxCIDLen    = 128  // defensive cap on a single CID string

	FeedPageSize  = 20  // posts per rendered page / default JSON window
	MaxPageLimit  = 100 // hard cap on any JSON read window (DoS guard)
	MaxRenderPage = 50  // deepest gnoweb page; beyond → use the cursor API

	// B1 reply bound (mirrors channels_v2's MaxRepliesPerThread). Caps the
	// LIVE reply set per post so (a) the byParent index under any one parent is
	// bounded, and (b) SweepTombstones can range-delete a swept parent's reply
	// links in bounded work. Deleting a reply frees a slot.
	MaxRepliesPerPost = 500

	// Flag pipeline. channels_v2 auto-hides at 3 member flags; the feed is
	// open-write, so the threshold starts higher and flagging is rate-limited.
	// These are damping knobs, not a brigade-proof gate: 5 aged sybils can
	// still hide a post (the age gate is one post + a one-time wait, farmable
	// in parallel). They raise the cost and slow coordination; genuine brigade
	// resistance is the W8.2 moderation board (reversible mod actions + audit).
	// All are governance-tunable post-deploy via a future realm version; they
	// are constants here so the adversarial tests pin their behavior.
	FlagThreshold        = 5     // unique flags before auto-hide
	MinAccountAgeForFlag = 1200  // blocks since first post (~1-2h)
	FlagsPerDayBudget    = 10    // per address per BlocksPerDay window
	BlocksPerDay         = 17280 // ~5s blocks; approximation is fine

	// Posting cooldowns (blocks). Young accounts (first seen < YoungAccountBlocks
	// ago) wait longer between posts — cheap sybil throttle.
	MinPostIntervalBlocks      = 2
	YoungMinPostIntervalBlocks = 12
	YoungAccountBlocks         = 17280 // first ~day
)

// ── Types ────────────────────────────────────────────────────

type Post struct {
	ID        uint64
	Author    address
	Body      string
	MediaCIDs []string // IPFS CIDs only; serving goes through the backend proxy
	ReplyTo   uint64   // 0 = top-level
	RepostOf  uint64   // 0 = original (entrypoint lands in P1; field is schema-stable)
	BlockH    int64
	EditedAt  int64 // block height of last edit (0 = never)
	FlagCount int
	Hidden    bool // flag auto-hide or moderation hide
	Deleted   bool // author tombstone (awaiting SweepTombstones hard-GC)
}

type flagBudget struct {
	DayStartH int64
	Used      int
}

// ── State ────────────────────────────────────────────────────

var (
	posts *avl.Tree // padID(id) -> *Post (live + hidden + not-yet-swept tombstones)

	// Live indexes (B1): ONLY visible (not hidden, not deleted) posts.
	// Every read path iterates one of these — never `posts`, never nextPostID.
	liveFeed   *avl.Tree // padID(id) -> true
	byAuthor   *avl.Tree // author + ":" + padID(id) -> true
	byParent   *avl.Tree // padID(parent) + ":" + padID(child) -> true
	liveCount  uint64    // number of keys in liveFeed
	replyCount *avl.Tree // padID(parent) -> uint64 (live replies)

	nextPostID uint64 // monotonic; NEVER iterated by reads

	// Anti-spam / flag state.
	lastPostH  *avl.Tree // addr -> int64 (last CreatePost height)
	firstSeenH *avl.Tree // addr -> int64 (first write interaction height)
	flags      *avl.Tree // padID(id) -> *avl.Tree (flagger addr -> true)
	flagSpend  *avl.Tree // addr -> *flagBudget

	// Reactions (one-per-emoji toggle). padID(id) -> *avl.Tree keyed by
	// reactionSubKey(emoji, addr) -> true. Enforces per-(post,emoji,addr)
	// uniqueness on-chain; per-emoji COUNTS are aggregated off-chain by the
	// indexer from ReactionAdded/ReactionRemoved (no unbounded on-chain scan —
	// B1 render bounds hold; a hot post's reaction set is never iterated here).
	reactions *avl.Tree

	// Soft-deleted post IDs awaiting hard-GC (B2). An AVL tree (not a slice):
	// a slice re-serializes wholesale on every enqueue, so post+delete spam
	// would inflate the gas of every write touching it (a slow write-path DoS).
	// The tree gives O(log n) enqueue and lets the sweep drain a bounded
	// ascending window without rewriting the backlog.
	tombstones *avl.Tree // padID(id) -> true

	// Moderator set (W8.2): owner-granted addresses that can ModRemovePost /
	// UnhidePost WITHOUT owner-multisig-per-post — fast, reversible moderation.
	// Granting/revoking stays owner-only. addr -> true.
	moderators *avl.Tree

	paused bool
	// Deployer address (samcrew-core-test1 multisig on testnet), captured at
	// package load — same pattern as channels_v2.
	owner = unsafe.OriginCaller()
)

func init() {
	posts = avl.NewTree()
	liveFeed = avl.NewTree()
	byAuthor = avl.NewTree()
	byParent = avl.NewTree()
	replyCount = avl.NewTree()
	lastPostH = avl.NewTree()
	firstSeenH = avl.NewTree()
	flags = avl.NewTree()
	flagSpend = avl.NewTree()
	reactions = avl.NewTree()
	moderators = avl.NewTree()
	tombstones = avl.NewTree()
	nextPostID = 1
}

// ── Helpers ──────────────────────────────────────────────────

// padID zero-pads to 12 digits so AVL string order == numeric order.
// 12 digits ≥ 31,000 years of one post per block — effectively unbounded.
func padID(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func getPost(id uint64) (*Post, bool) {
	v, ok := posts.Get(padID(id))
	if !ok {
		return nil, false
	}
	return v.(*Post), true
}

func mustGetPost(id uint64) *Post {
	p, ok := getPost(id)
	if !ok {
		panic("post not found: " + strconv.FormatUint(id, 10))
	}
	return p
}

func authorKey(addr address, id uint64) string { return addr.String() + ":" + padID(id) }
func parentKey(parent, child uint64) string    { return padID(parent) + ":" + padID(child) }

func getReplyCount(parent uint64) uint64 {
	if v, ok := replyCount.Get(padID(parent)); ok {
		return v.(uint64)
	}
	return 0
}

// addToLiveIndexes registers a visible post in every live index (B1).
//
// A reply is only linked into its parent's byParent/replyCount indexes when the
// parent is still LIVE. On CreatePost the parent was just verified live, so this
// is always true there. The guard matters on the UnhidePost re-add path: if the
// parent was deleted+swept while the reply sat hidden, re-linking would recreate
// an orphan byParent/replyCount entry under a parent id no longer in `posts`
// (never sweepable again) — the exact leak SweepTombstones' byParent-prefix
// cleanup was added to prevent. An unhidden reply whose parent is gone simply
// becomes standalone live content, which is how a reply to a removed parent is
// already treated everywhere else.
func addToLiveIndexes(p *Post) {
	liveFeed.Set(padID(p.ID), true)
	byAuthor.Set(authorKey(p.Author, p.ID), true)
	liveCount++
	if p.ReplyTo != 0 && liveFeed.Has(padID(p.ReplyTo)) {
		byParent.Set(parentKey(p.ReplyTo, p.ID), true)
		replyCount.Set(padID(p.ReplyTo), getReplyCount(p.ReplyTo)+1)
	}
}

// removeFromLiveIndexes drops a post from every live index (hide/delete).
func removeFromLiveIndexes(p *Post) {
	if _, ok := liveFeed.Get(padID(p.ID)); !ok {
		return // already invisible (e.g. delete after auto-hide)
	}
	liveFeed.Remove(padID(p.ID))
	byAuthor.Remove(authorKey(p.Author, p.ID))
	if liveCount > 0 {
		liveCount--
	}
	if p.ReplyTo != 0 {
		byParent.Remove(parentKey(p.ReplyTo, p.ID))
		if rc := getReplyCount(p.ReplyTo); rc > 0 {
			replyCount.Set(padID(p.ReplyTo), rc-1)
		}
	}
}

func assertNotPaused() {
	if paused {
		panic("realm is paused — emergency maintenance")
	}
}

func assertCallerIsOwner() {
	caller := unsafe.PreviousRealm().Address()
	if caller != owner {
		panic("unauthorized: caller " + caller.String() + " is not the owner")
	}
}

// touchFirstSeen records the first write interaction height for an address.
func touchFirstSeen(addr address, h int64) {
	if _, ok := firstSeenH.Get(addr.String()); !ok {
		firstSeenH.Set(addr.String(), h)
	}
}

func accountAge(addr address, now int64) int64 {
	if v, ok := firstSeenH.Get(addr.String()); ok {
		return now - v.(int64)
	}
	return 0
}

// ── Emergency pause (B3 — one policy, enforced everywhere) ───
// While paused every user-facing content write is blocked. Owner moderation
// and pause management stay live: pause halts user activity during an
// incident, but the owner must stay able to act. No funds here, so there is
// no value-exit exemption to carve out.

func PauseRealm(cur realm) {
	assertCallerIsOwner()
	paused = true
	chain.Emit("RealmPaused", "by", owner.String())
}

func UnpauseRealm(cur realm) {
	assertCallerIsOwner()
	paused = false
	chain.Emit("RealmUnpaused", "by", owner.String())
}

func IsPaused() bool { return paused }

// TransferOwnership moves realm ownership (deployer multisig rotation).
func TransferOwnership(cur realm, newOwner address) {
	assertCallerIsOwner()
	if newOwner == "" {
		panic("address cannot be empty")
	}
	if newOwner == owner {
		panic("new owner is the same as current owner")
	}
	prev := owner
	owner = newOwner
	chain.Emit("OwnershipTransferred",
		"previousOwner", prev.String(),
		"newOwner", newOwner.String(),
	)
}

// GetOwner returns the current realm owner address.
func GetOwner() address { return owner }

// ── Writes ───────────────────────────────────────────────────

// CreatePost publishes a post (replyTo == 0) or a reply (replyTo == parent id).
// Open write: any wallet, subject to the block cooldown and body caps.
// Returns the new post id.
func CreatePost(cur realm, body string, replyTo uint64) uint64 {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	now := runtime.ChainHeight()

	// Cooldown BEFORE touching state: young accounts wait longer.
	touchFirstSeen(caller, now)
	interval := int64(MinPostIntervalBlocks)
	if accountAge(caller, now) < YoungAccountBlocks {
		interval = YoungMinPostIntervalBlocks
	}
	if v, ok := lastPostH.Get(caller.String()); ok {
		if now-v.(int64) < interval {
			panic(ufmt.Sprintf("posting too fast: wait %d blocks between posts", interval))
		}
	}

	if len(body) == 0 || len(body) > MaxBodyLen {
		panic(ufmt.Sprintf("body must be 1-%d characters", MaxBodyLen))
	}

	var parent *Post
	if replyTo != 0 {
		parent = mustGetPost(replyTo)
		if parent.Deleted {
			panic("cannot reply to a deleted post")
		}
		if parent.Hidden {
			panic("cannot reply to a hidden post")
		}
		// B1: bound the LIVE reply set so the byParent index under one parent
		// stays bounded (and a swept parent's link cleanup stays bounded).
		if getReplyCount(replyTo) >= MaxRepliesPerPost {
			panic(ufmt.Sprintf("reply limit reached: %d per post", MaxRepliesPerPost))
		}
	}

	id := nextPostID
	nextPostID++

	p := &Post{
		ID:      id,
		Author:  caller,
		Body:    body,
		ReplyTo: replyTo,
		BlockH:  now,
	}
	posts.Set(padID(id), p)
	addToLiveIndexes(p)
	lastPostH.Set(caller.String(), now)

	chain.Emit("PostCreated",
		"postId", strconv.FormatUint(id, 10),
		"author", caller.String(),
		"replyTo", strconv.FormatUint(replyTo, 10),
		"body", body,
	)
	return id
}

// EditPost lets the author replace the body of a visible post.
func EditPost(cur realm, id uint64, newBody string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	p := mustGetPost(id)
	if p.Author != caller {
		panic("only the author can edit")
	}
	if p.Deleted {
		panic("cannot edit a deleted post")
	}
	if p.Hidden {
		panic("cannot edit a hidden post")
	}
	if len(newBody) == 0 || len(newBody) > MaxBodyLen {
		panic(ufmt.Sprintf("body must be 1-%d characters", MaxBodyLen))
	}

	p.Body = newBody
	p.EditedAt = runtime.ChainHeight()
	posts.Set(padID(id), p)

	chain.Emit("PostEdited",
		"postId", strconv.FormatUint(id, 10),
		"author", caller.String(),
		"body", newBody,
	)
}

// DeletePost soft-deletes the author's own post: content cleared, dropped from
// every live index (frees render slots immediately — B1), queued for hard-GC
// (B2). Replies stay: they render as replies to an unavailable post.
func DeletePost(cur realm, id uint64) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	p := mustGetPost(id)
	if p.Author != caller {
		panic("only the author can delete")
	}
	if p.Deleted {
		panic("post already deleted")
	}

	removeFromLiveIndexes(p)
	p.Deleted = true
	p.Body = ""
	p.MediaCIDs = nil
	posts.Set(padID(id), p)
	tombstones.Set(padID(id), true)

	chain.Emit("PostDeleted",
		"postId", strconv.FormatUint(id, 10),
		"author", caller.String(),
	)
}

// ── Flag pipeline ────────────────────────────────────────────

// FlagPost files a community flag. Guards, in order:
//   - flag rights are EARNED BY PARTICIPATION: the caller must have a
//     firstSeen record (anchored by their first successful CreatePost) at
//     least MinAccountAgeForFlag blocks old. A failed flag cannot anchor age
//     itself — an on-chain abort reverts every write in the tx, so recording
//     firstSeen here and then panicking would revert the record and deadlock
//     pure flaggers; requiring a prior post is the honest, implementable
//     account-age gate (realms cannot query global account age);
//   - one flag per address per post;
//   - per-day flag budget per address (blunts coordinated flag-brigades).
//
// At FlagThreshold unique flags the post auto-hides (reversible via UnhidePost).
func FlagPost(cur realm, id uint64) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	now := runtime.ChainHeight()

	if accountAge(caller, now) < MinAccountAgeForFlag {
		panic(ufmt.Sprintf("flagging requires having posted at least %d blocks ago", MinAccountAgeForFlag))
	}

	p := mustGetPost(id)
	if p.Deleted {
		panic("cannot flag a deleted post")
	}
	if p.Hidden {
		panic("post is already hidden")
	}

	// Per-day budget window.
	var fb *flagBudget
	if v, ok := flagSpend.Get(caller.String()); ok {
		fb = v.(*flagBudget)
	} else {
		fb = &flagBudget{DayStartH: now}
	}
	if now-fb.DayStartH >= BlocksPerDay {
		fb.DayStartH = now
		fb.Used = 0
	}
	if fb.Used >= FlagsPerDayBudget {
		panic(ufmt.Sprintf("daily flag budget reached: %d per %d blocks", FlagsPerDayBudget, BlocksPerDay))
	}

	// Unique flaggers per post.
	var flagTree *avl.Tree
	if v, ok := flags.Get(padID(id)); ok {
		flagTree = v.(*avl.Tree)
	} else {
		flagTree = avl.NewTree()
	}
	if _, already := flagTree.Get(caller.String()); already {
		panic("already flagged")
	}
	flagTree.Set(caller.String(), true)
	flags.Set(padID(id), flagTree)

	fb.Used++
	flagSpend.Set(caller.String(), fb)

	p.FlagCount = flagTree.Size()
	wasHidden := p.Hidden
	if p.FlagCount >= FlagThreshold {
		p.Hidden = true
		removeFromLiveIndexes(p)
		// A flag-hidden post is deliberately NOT tombstoned: its node and its
		// `flags` subtree (the flagger set) are retained on purpose as the audit
		// trail the W8.2 moderation board reviews (and UnhidePost needs, to
		// reverse a brigade). It leaves the live indexes (B1 render bounds still
		// hold), so this is bounded, intentional retention — not a leak. Author
		// delete / mod-remove are the paths that tombstone for GC.
	}
	posts.Set(padID(id), p)

	chain.Emit("PostFlagged",
		"postId", strconv.FormatUint(id, 10),
		"flagger", caller.String(),
		"flagCount", strconv.Itoa(p.FlagCount),
	)
	if !wasHidden && p.Hidden {
		chain.Emit("PostAutoHidden", "postId", strconv.FormatUint(id, 10))
	}
}

// ── Reactions (one-per-emoji toggle; open-write, gas is the throttle) ─
//
// A wallet may add each supported emoji at most once per post, and remove it
// again. Reactions carry no content (no DoS/GDPR surface like a post body), so
// there is no account-age gate — the per-(post,emoji,addr) dedup plus the gas
// cost of an on-chain tx are the throttle. Per-emoji COUNTS are aggregated
// off-chain by the indexer from the events below; the realm NEVER scans a
// post's reaction set, so the B1 render bounds are untouched.

// reactionEmojis is the fixed on-chain reaction set. Changing it is a realm
// version bump (redeploy), so it is deliberately small and stable.
var reactionEmojis = []string{"👍", "❤️", "😂", "😮", "😢", "🔥", "🎉", "👀", "🚀"}

func isReactionEmoji(e string) bool {
	for _, r := range reactionEmojis {
		if r == e {
			return true
		}
	}
	return false
}

// reactionSubKey namespaces a reactor's entry within a post's reaction tree.
// The NUL separator cannot appear in a fixed-set emoji or a bech32 address, so
// (emoji, addr) round-trips unambiguously.
func reactionSubKey(emoji string, addr address) string {
	return emoji + "\x00" + addr.String()
}

// HasReacted reports whether addr currently has the given emoji on the post.
// O(log n) point lookup — never a scan.
func HasReacted(id uint64, emoji string, addr address) bool {
	v, ok := reactions.Get(padID(id))
	if !ok {
		return false
	}
	_, exists := v.(*avl.Tree).Get(reactionSubKey(emoji, addr))
	return exists
}

// AddReaction records the caller's emoji reaction. A repeat aborts (rather than
// no-op) so an optimistic client's double-tap cannot silently burn gas twice —
// the client gates the button on HasReacted / indexed state.
func AddReaction(cur realm, id uint64, emoji string) {
	assertNotPaused()
	if !isReactionEmoji(emoji) {
		panic("unsupported reaction")
	}
	caller := unsafe.PreviousRealm().Address()
	now := runtime.ChainHeight()

	p := mustGetPost(id)
	if p.Deleted {
		panic("cannot react to a deleted post")
	}
	if p.Hidden {
		panic("cannot react to a hidden post")
	}
	touchFirstSeen(caller, now)

	var tree *avl.Tree
	if v, ok := reactions.Get(padID(id)); ok {
		tree = v.(*avl.Tree)
	} else {
		tree = avl.NewTree()
	}
	key := reactionSubKey(emoji, caller)
	if _, already := tree.Get(key); already {
		panic("already reacted with this emoji")
	}
	tree.Set(key, true)
	reactions.Set(padID(id), tree)

	chain.Emit("ReactionAdded",
		"postId", strconv.FormatUint(id, 10),
		"emoji", emoji,
		"by", caller.String(),
	)
}

// RemoveReaction removes the caller's emoji reaction (toggle-off). Allowed even
// on a hidden/deleted post so a reactor can always retract; aborts if the caller
// had not reacted with that emoji.
func RemoveReaction(cur realm, id uint64, emoji string) {
	assertNotPaused()
	if !isReactionEmoji(emoji) {
		panic("unsupported reaction")
	}
	caller := unsafe.PreviousRealm().Address()
	mustGetPost(id) // aborts if the post never existed

	v, ok := reactions.Get(padID(id))
	if !ok {
		panic("you have not reacted to this post")
	}
	tree := v.(*avl.Tree)
	key := reactionSubKey(emoji, caller)
	if _, exists := tree.Get(key); !exists {
		panic("you have not reacted with this emoji")
	}
	tree.Remove(key)
	if tree.Size() == 0 {
		reactions.Remove(padID(id)) // GC the empty subtree
	} else {
		reactions.Set(padID(id), tree)
	}

	chain.Emit("ReactionRemoved",
		"postId", strconv.FormatUint(id, 10),
		"emoji", emoji,
		"by", caller.String(),
	)
}

// ── Moderator role (W8.2) ────────────────────────────────────
// The owner grants/revokes moderator addresses that can ModRemovePost /
// UnhidePost. Fast (no owner-multisig-per-post) and reversible; grant/revoke
// stays owner-only. Every mutation is emitted for public audit.

func assertCallerIsOwnerOrModerator() {
	caller := unsafe.PreviousRealm().Address()
	if caller == owner {
		return
	}
	if _, ok := moderators.Get(caller.String()); ok {
		return
	}
	panic("unauthorized: caller " + caller.String() + " is not the owner or a moderator")
}

// IsModerator reports whether addr currently holds the moderator role.
func IsModerator(addr address) bool {
	_, ok := moderators.Get(addr.String())
	return ok
}

// AddModerator grants the moderator role (owner only).
func AddModerator(cur realm, addr address) {
	assertCallerIsOwner()
	if addr == "" {
		panic("address cannot be empty")
	}
	moderators.Set(addr.String(), true)
	chain.Emit("ModeratorAdded", "moderator", addr.String(), "by", owner.String())
}

// RemoveModerator revokes the moderator role (owner only).
func RemoveModerator(cur realm, addr address) {
	assertCallerIsOwner()
	if _, ok := moderators.Get(addr.String()); !ok {
		panic("address is not a moderator")
	}
	moderators.Remove(addr.String())
	chain.Emit("ModeratorRemoved", "moderator", addr.String(), "by", owner.String())
}

// ── Moderation (owner OR moderator; W8.2 hot-key lever) ───────

// ModRemovePost permanently hides a post by moderation. Emits an audited
// ModAction. The node is tombstoned for hard-GC like an author delete.
func ModRemovePost(cur realm, id uint64) {
	assertCallerIsOwnerOrModerator()

	p := mustGetPost(id)
	if !p.Deleted {
		removeFromLiveIndexes(p)
		tombstones.Set(padID(id), true)
	}
	p.Deleted = true
	p.Hidden = true
	p.Body = ""
	p.MediaCIDs = nil
	posts.Set(padID(id), p)

	chain.Emit("ModAction",
		"action", "remove",
		"postId", strconv.FormatUint(id, 10),
		"moderator", unsafe.PreviousRealm().Address().String(),
	)
}

// UnhidePost clears flags and restores a flag-hidden post to the live set.
func UnhidePost(cur realm, id uint64) {
	assertCallerIsOwnerOrModerator()

	p := mustGetPost(id)
	if p.Deleted {
		panic("cannot unhide a deleted post")
	}
	if !p.Hidden {
		panic("post is not hidden")
	}
	p.Hidden = false
	p.FlagCount = 0
	posts.Set(padID(id), p)
	flags.Remove(padID(id))
	addToLiveIndexes(p)

	chain.Emit("ModAction",
		"action", "unhide",
		"postId", strconv.FormatUint(id, 10),
		"moderator", unsafe.PreviousRealm().Address().String(),
	)
}

// ── Tombstone sweep (B2 hard-GC, ported from channels_v2) ────

// SweepTombstones hard-removes up to `limit` soft-deleted posts, reclaiming
// AVL storage so post+delete spam cannot accrete permanent state.
// Permissionless by design (state-shrink hygiene primitive, not a refund
// path). Bounded + idempotent: keep `limit` small (1-10); re-running drains
// the next batch and stops at 0. Returns the number of posts swept.
//
// For a swept post that was a PARENT, its surviving replies' byParent links
// (`padID(parent):padID(child)`) would otherwise be orphaned under an id no
// longer in `posts` — a permanent leak plus a read inconsistency (replies
// still enumerable, getReplyCount() disagreeing). So the sweep range-deletes
// that byParent prefix; the reply posts themselves stay as standalone live
// content (their parent was removed by its own author). Bounded because the
// live reply set per post is capped at MaxRepliesPerPost — but a reply-heavy
// parent makes one sweep step do up to that many removes, so keep `limit`
// small (1) when draining known reply-heavy tombstones.
func SweepTombstones(cur realm, limit int) int {
	assertNotPaused()
	if limit <= 0 {
		return 0
	}

	// Collect the oldest `limit` tombstoned ids (ascending), then mutate —
	// never remove from the tree we are iterating (AVL footgun).
	ids := []uint64{}
	tombstones.Iterate("", "", func(key string, _ interface{}) bool {
		ids = append(ids, idFromPadded(key))
		return len(ids) >= limit
	})

	for _, id := range ids {
		// Drop this parent's remaining child links (if any) so no byParent
		// entry outlives its parent. Collect-then-remove over the prefix.
		prefix := padID(id) + ":"
		childKeys := []string{}
		byParent.Iterate(prefix, prefix+"\xff", func(k string, _ interface{}) bool {
			childKeys = append(childKeys, k)
			return false
		})
		for _, k := range childKeys {
			byParent.Remove(k)
		}

		posts.Remove(padID(id))
		flags.Remove(padID(id))
		replyCount.Remove(padID(id))
		tombstones.Remove(padID(id))
	}

	if len(ids) > 0 {
		chain.Emit("TombstonesSwept", "count", strconv.Itoa(len(ids)))
	}
	return len(ids)
}

// GetTombstoneCount returns how many soft-deleted posts await hard-GC.
func GetTombstoneCount() int { return tombstones.Size() }

// ── JSON reads (vm/qeval; cursor-paginated, O(limit) at any depth) ──

// jsonEscape escapes a string for embedding in a JSON string literal.
func jsonEscape(s string) string {
	var sb strings.Builder
	for _, c := range s {
		switch c {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if c < 0x20 {
				continue // drop raw control chars (ufmt has no \uXXXX support)
			}
			sb.WriteRune(c)
		}
	}
	return sb.String()
}

// postJSON is the qeval read fallback. Note it exposes `mediaCids` (P2) and
// `repostOf` (P1) which the CANONICAL indexed path (chain.Emit → backend →
// feed_rpc → UI) does NOT carry yet — PostCreated emits neither, the proto
// reserves repost_of, and there is no media column. A future dev wiring the
// qeval fallback must not assume those two are plumbed end-to-end.
func postJSON(p *Post) string {
	var media strings.Builder
	media.WriteString("[")
	for i, cid := range p.MediaCIDs {
		if i > 0 {
			media.WriteString(",")
		}
		media.WriteString("\"" + jsonEscape(cid) + "\"")
	}
	media.WriteString("]")

	return ufmt.Sprintf(
		`{"id":%d,"author":"%s","body":"%s","mediaCids":%s,"replyTo":%d,"repostOf":%d,"blockH":%d,"editedAt":%d,"flagCount":%d,"hidden":%s,"deleted":%s,"replies":%d}`,
		p.ID, p.Author.String(), jsonEscape(p.Body), media.String(),
		p.ReplyTo, p.RepostOf, p.BlockH, p.EditedAt, p.FlagCount,
		boolStr(p.Hidden), boolStr(p.Deleted), getReplyCount(p.ID),
	)
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func clampLimit(limit int) int {
	if limit <= 0 {
		return FeedPageSize
	}
	if limit > MaxPageLimit {
		return MaxPageLimit
	}
	return limit
}

// GetPostJSON returns one post (any state — the indexer needs tombstones too).
func GetPostJSON(id uint64) string {
	p, ok := getPost(id)
	if !ok {
		return "null"
	}
	return postJSON(p)
}

// listWindow walks `tree` REVERSE (newest first) starting below cursorKey
// ("" = from the newest), collecting up to limit ids via extract.
func listWindow(tree *avl.Tree, cursorKey string, limit int, extract func(key string) uint64) []uint64 {
	ids := []uint64{}
	count := 0
	tree.ReverseIterate("", cursorKey, func(key string, _ interface{}) bool {
		id := extract(key)
		if id != 0 {
			ids = append(ids, id)
			count++
		}
		return count >= limit
	})
	return ids
}

func idFromPadded(key string) uint64 {
	n, err := strconv.ParseUint(key, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

func idFromComposite(key string) uint64 {
	i := strings.LastIndexByte(key, ':')
	if i < 0 {
		return 0
	}
	return idFromPadded(key[i+1:])
}

func idsToJSON(ids []uint64) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, id := range ids {
		if i > 0 {
			sb.WriteString(",")
		}
		if p, ok := getPost(id); ok {
			sb.WriteString(postJSON(p))
		}
	}
	sb.WriteString("]")
	return sb.String()
}

// ListFeedJSON returns the newest live posts strictly older than cursor
// (cursor == 0 → from the top). Pass the last id of the previous window as
// the next cursor.
//
// ReverseIterate treats BOTH bounds as inclusive (avl/v0 TraverseInRange), so
// "strictly older than cursor" = end bound padID(cursor-1): ids are integers,
// keys are fixed-width, hence key < padID(cursor) ⟺ key ≤ padID(cursor-1).
func ListFeedJSON(cursor uint64, limit int) string {
	limit = clampLimit(limit)
	cursorKey := ""
	if cursor != 0 {
		cursorKey = padID(cursor - 1)
	}
	return idsToJSON(listWindow(liveFeed, cursorKey, limit, idFromPadded))
}

// ListUserJSON returns a user's newest live posts strictly older than cursor
// (same inclusive-bound rule as ListFeedJSON).
func ListUserJSON(addr string, cursor uint64, limit int) string {
	limit = clampLimit(limit)
	cursorKey := ""
	if cursor != 0 {
		cursorKey = addr + ":" + padID(cursor-1)
	} else {
		// End bound just past every "addr:XXXXXXXXXXXX" key: ':' + 0xff.
		cursorKey = addr + ":\xff"
	}
	ids := []uint64{}
	count := 0
	byAuthor.ReverseIterate(addr+":", cursorKey, func(key string, _ interface{}) bool {
		if id := idFromComposite(key); id != 0 {
			ids = append(ids, id)
			count++
		}
		return count >= limit
	})
	return idsToJSON(ids)
}

// ListRepliesJSON returns a post's live replies, OLDEST first (conversation
// order), starting strictly after cursor (0 → from the beginning).
func ListRepliesJSON(parent uint64, cursor uint64, limit int) string {
	limit = clampLimit(limit)
	start := padID(parent) + ":"
	if cursor != 0 {
		start = parentKey(parent, cursor) + "\x00" // strictly after the cursor child
	}
	ids := []uint64{}
	count := 0
	byParent.Iterate(start, padID(parent)+":\xff", func(key string, _ interface{}) bool {
		if id := idFromComposite(key); id != 0 {
			ids = append(ids, id)
			count++
		}
		return count >= limit
	})
	return idsToJSON(ids)
}

// GetStatsJSON returns realm-level counters (monotonic id is informational —
// no read iterates it).
func GetStatsJSON() string {
	return ufmt.Sprintf(`{"livePosts":%d,"nextPostId":%d,"tombstones":%d,"paused":%s}`,
		liveCount, nextPostID, tombstones.Size(), boolStr(paused))
}

// ── Render (gnoweb human view; bounded — B1) ─────────────────
//
// Paths:
//   ""            → newest window (page 1)
//   page/K        → K-th newest window, K ≤ MaxRenderPage
//   user/ADDR     → ADDR's newest window
//   user/ADDR/K   → K-th window of ADDR's posts
//   post/ID       → one post + its newest reply window
//
// Every page scans at most MaxRenderPage*FeedPageSize live-index keys and
// fetches at most FeedPageSize posts — bounded regardless of feed size or
// churn (deleted/hidden posts are not in the live indexes at all).

func Render(path string) string {
	if path == "" {
		return renderFeedPage(1)
	}
	if strings.HasPrefix(path, "page/") {
		k, err := strconv.ParseUint(strings.TrimPrefix(path, "page/"), 10, 64)
		if err != nil || k == 0 {
			return "# 404\nBad page"
		}
		return renderFeedPage(k)
	}
	if strings.HasPrefix(path, "user/") {
		rest := strings.TrimPrefix(path, "user/")
		addr := rest
		k := uint64(1)
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			addr = rest[:i]
			n, err := strconv.ParseUint(rest[i+1:], 10, 64)
			if err != nil || n == 0 {
				return "# 404\nBad page"
			}
			k = n
		}
		return renderUserPage(addr, k)
	}
	if strings.HasPrefix(path, "post/") {
		id, err := strconv.ParseUint(strings.TrimPrefix(path, "post/"), 10, 64)
		if err != nil {
			return "# 404\nBad post id"
		}
		return renderPost(id)
	}
	return "# 404\nPage not found: " + path
}

// collectPage walks a live index reverse and returns the ids for window k
// (1-based). Scan is bounded: k is capped at MaxRenderPage by callers.
func collectPage(tree *avl.Tree, prefix, endKey string, k uint64) []uint64 {
	skip := (k - 1) * FeedPageSize
	ids := []uint64{}
	seen := uint64(0)
	tree.ReverseIterate(prefix, endKey, func(key string, _ interface{}) bool {
		if seen >= skip {
			var id uint64
			if prefix == "" {
				id = idFromPadded(key)
			} else {
				id = idFromComposite(key)
			}
			if id != 0 {
				ids = append(ids, id)
			}
		}
		seen++
		return len(ids) >= FeedPageSize
	})
	return ids
}

func renderPostLine(sb *strings.Builder, p *Post) {
	sb.WriteString(ufmt.Sprintf("**%s** (block %d)", truncAddr(p.Author), p.BlockH))
	if p.EditedAt != 0 {
		sb.WriteString(" *(edited)*")
	}
	if p.ReplyTo != 0 {
		sb.WriteString(ufmt.Sprintf(" — reply to [post %d](:post/%d)", p.ReplyTo, p.ReplyTo))
	}
	sb.WriteString("\n\n")
	sb.WriteString(sanitizeForRender(p.Body) + "\n\n")
	rc := getReplyCount(p.ID)
	sb.WriteString(ufmt.Sprintf("[permalink](:post/%d) | %d replies\n\n---\n\n", p.ID, rc))
}

func renderFeedPage(k uint64) string {
	if k > MaxRenderPage {
		return ufmt.Sprintf("# Memba Feed\n\n*Pages beyond %d are not rendered — use the JSON cursor API (ListFeedJSON) or the Memba app.*\n", MaxRenderPage)
	}
	var sb strings.Builder
	sb.WriteString("# Memba Feed\n\n")
	sb.WriteString(ufmt.Sprintf("**Live posts:** %d\n\n", liveCount))

	ids := collectPage(liveFeed, "", "", k)
	if len(ids) == 0 {
		sb.WriteString("*No posts on this page.*\n")
		return sb.String()
	}
	for _, id := range ids {
		if p, ok := getPost(id); ok {
			renderPostLine(&sb, p)
		}
	}
	sb.WriteString(ufmt.Sprintf("*page %d — older: `:page/%d`*\n", k, k+1))
	return sb.String()
}

func renderUserPage(addr string, k uint64) string {
	if k > MaxRenderPage {
		return ufmt.Sprintf("# Feed — %s\n\n*Pages beyond %d are not rendered — use ListUserJSON or the Memba app.*\n", addr, MaxRenderPage)
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Feed — %s\n\n", addr))
	ids := collectPage(byAuthor, addr+":", addr+":\xff", k)
	if len(ids) == 0 {
		sb.WriteString("*No posts on this page.*\n")
		return sb.String()
	}
	for _, id := range ids {
		if p, ok := getPost(id); ok {
			renderPostLine(&sb, p)
		}
	}
	sb.WriteString(ufmt.Sprintf("*page %d — older: `:user/%s/%d`*\n", k, addr, k+1))
	return sb.String()
}

func renderPost(id uint64) string {
	p, ok := getPost(id)
	if !ok {
		return "# 404\nPost not found"
	}
	// Same suppression rule as channels_v2: the direct path must not leak
	// hidden/deleted content.
	if p.Hidden || p.Deleted {
		return "# Post unavailable\n\n*This post has been hidden or removed.*\n"
	}

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Post %d\n\n", p.ID))
	renderPostLine(&sb, p)

	// Newest reply window only (fixed size); full thread = JSON cursor API.
	rc := getReplyCount(p.ID)
	if rc > 0 {
		sb.WriteString("## Replies\n\n")
		if rc > FeedPageSize {
			sb.WriteString(ufmt.Sprintf("*Showing the %d newest of %d — full thread via ListRepliesJSON or the app.*\n\n", FeedPageSize, rc))
		}
		ids := collectPage(byParent, padID(p.ID)+":", padID(p.ID)+":\xff", 1)
		// collectPage walks reverse (newest first); show oldest→newest.
		for i := len(ids) - 1; i >= 0; i-- {
			if r, ok := getPost(ids[i]); ok {
				renderPostLine(&sb, r)
			}
		}
	}
	return sb.String()
}

// ── Shared render helpers (ported verbatim from channels_v2) ─

func truncAddr(addr address) string {
	s := string(addr)
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

// sanitizeForRender strips markdown-sensitive characters to prevent injection.
func sanitizeForRender(s string) string {
	var out strings.Builder
	for _, c := range s {
		switch c {
		case '[', ']', '(', ')', '#', '*', '`', '!', '<', '>', '|', '\\', '_', '~', '\n', '\r', '\t':
			continue
		default:
			out.WriteRune(c)
		}
	}
	return out.String()
}
