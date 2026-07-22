package memba_dao_channels_v2

// memba_dao_channels — Social feed realm for MembaDAO.
//
// Provides Discord-like channels with threads, replies, and moderation.
// The Render() output MUST match the regex patterns in parser.ts (frontend).
//
// Render() contract (from parser.ts):
//
//   Home — Render(""):
//     # BoardName
//     description
//     ## Channels
//     - [#name](:_channel/name) 📢 (N threads)
//
//   Channel — Render("channelName"):
//     # #channelName
//     ### [Title](:channel/id)
//     by g1addr... | N replies | block H
//
//   Thread — Render("channel/id"):
//     # Title
//     body
//     ---
//     *Posted by g1addr at block H*
//     ## Replies
//     **g1addr...** (block H)
//     reply body
//     ---
//
//   ACL — Render("__acl/channel"):
//     read:role1,role2
//     write:role1,role2,role3
//     type:text
//
// Security:
//   - All write operations require membership (AddMember by owner)
//   - PostThread/PostReply check caller's roles against channel WriteRoles
//   - CreateChannel/RemoveThread restricted to owner only
//   - FlagThread requires membership (prevents sybil flagging by non-members)
//   - EditThread/DeleteThread require membership + original author check
//
// Moderation: flag → threshold (3) → auto-hide → DAO vote → remove

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/samcrew/avl"
	"gno.land/p/nt/ufmt/v0"
)

// ── Constants ────────────────────────────────────────────────

const (
	MaxPostLen        = 5000
	MaxTitleLen       = 200
	MaxChannels       = 20
	MaxThreadsPerChan = 500
	FlagThreshold     = 3 // flags before auto-hide

	// AAA-1 B1 — render-DoS bounds for replies (mirrors MaxThreadsPerChan).
	// renderThread must never iterate the monotonic reply counter (post+delete
	// reply spam would inflate it without bound → unbounded render scan →
	// thread permanently unrenderable past maxGasQuery). The live-reply index
	// (replyLive/replyLiveIDs) caps the live set, and renderThread paginates a
	// fixed window over it, so render cost is bounded regardless of churn.
	MaxRepliesPerThread = 500 // live (non-deleted) replies per thread
	ReplyPageSize       = 50  // replies rendered per page
)

// ── Types ────────────────────────────────────────────────────

type ChannelType string

const (
	ChannelText          ChannelType = "text"
	ChannelAnnouncements ChannelType = "announcements"
	ChannelReadonly      ChannelType = "readonly"
)

type Channel struct {
	Name        string
	Description string
	Type        ChannelType
	Archived    bool
	ReadRoles   []string // roles that can read
	WriteRoles  []string // roles that can write
}

type Thread struct {
	ID        uint64
	Channel   string
	Title     string
	Body      string
	Author    address
	BlockH    int64
	Edited    bool
	EditedAt  int64
	Deleted   bool
	FlagCount int
	Hidden    bool
}

type Reply struct {
	ID       uint64
	ThreadID uint64
	Channel  string
	Body     string
	Author   address
	BlockH   int64
	Edited   bool
}

// ── State ────────────────────────────────────────────────────

var (
	channels      *avl.Tree // name -> *Channel
	threads       *avl.Tree // "channel/id" -> *Thread
	replies       *avl.Tree // "channel/threadId/replyId" -> *Reply
	threadCount   *avl.Tree // channel -> uint64 (next thread ID, monotonic)
	threadLive    *avl.Tree // channel -> uint64 (currently live (non-deleted) threads)
	threadLiveIDs *avl.Tree // channel -> []uint64 (live thread IDs, ascending) — bounds renderChannel
	replyCount    *avl.Tree // "channel/threadId" -> uint64 (next reply ID, monotonic)
	replyLive     *avl.Tree // "channel/threadId" -> uint64 (currently live (non-deleted) replies)
	replyLiveIDs  *avl.Tree // "channel/threadId" -> []uint64 (live reply IDs, ascending) — bounds renderThread
	threadTomb    *avl.Tree // channel -> []uint64 (soft-deleted thread IDs awaiting hard-GC via SweepTombstones) — B2
	flags         *avl.Tree // "channel/threadId" -> *avl.Tree (flagger addr -> bool)
	channelOrder  []string  // ordered channel names

	// Membership: address -> comma-separated roles (e.g., "admin,dev")
	members *avl.Tree
	paused  bool
	// Owner is set at package load time via OriginCaller() — this captures the
	// deployer address (samcrew-core-test1 multisig on testnet).
	owner = unsafe.OriginCaller()
)

func init() {
	channels = avl.NewTree()
	threads = avl.NewTree()
	replies = avl.NewTree()
	threadCount = avl.NewTree()
	threadLive = avl.NewTree()
	threadLiveIDs = avl.NewTree()
	replyCount = avl.NewTree()
	replyLive = avl.NewTree()
	replyLiveIDs = avl.NewTree()
	threadTomb = avl.NewTree()
	flags = avl.NewTree()
	channelOrder = []string{}
	members = avl.NewTree()
	members.Set(owner.String(), "admin")

	// Default channels matching MEMBA_DAO_CHANNELS in config.ts
	addChannel("general", "General discussion for all members", ChannelText,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin", "dev", "ops", "member"})
	addChannel("announcements", "Official MembaDAO announcements — admin-write-only", ChannelAnnouncements,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin"})
	addChannel("feature-requests", "Propose and discuss new features", ChannelText,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin", "dev", "ops", "member"})
	addChannel("support", "Help and troubleshooting", ChannelText,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin", "dev", "ops", "member"})
	addChannel("extensions", "Plugin and extension development", ChannelText,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin", "dev", "member"})
	addChannel("partnerships", "Collaboration and partnership proposals", ChannelText,
		[]string{"admin", "dev", "ops", "member"}, []string{"admin", "dev", "ops", "member"})
}

// ── Channel Management ───────────────────────────────────────

func addChannel(name, description string, ctype ChannelType, readRoles, writeRoles []string) {
	ch := &Channel{
		Name:        name,
		Description: description,
		Type:        ctype,
		Archived:    false,
		ReadRoles:   readRoles,
		WriteRoles:  writeRoles,
	}
	channels.Set(name, ch)
	threadCount.Set(name, uint64(0))
	threadLive.Set(name, uint64(0))
	channelOrder = append(channelOrder, name)
}

// ── Membership Management ───────────────────────────────────

// AddMember adds an address with specified roles. Only the owner can call this.
// roles is a comma-separated list (e.g., "admin,dev" or "member").
func AddMember(cur realm, addr address, roles string) {
	assertCallerIsOwner()
	if addr == "" {
		panic("address cannot be empty")
	}
	if len(roles) == 0 {
		panic("roles cannot be empty")
	}
	if !isValidRoles(roles) {
		panic("invalid roles: must be comma-separated alphanumeric only")
	}
	members.Set(addr.String(), roles)

	chain.Emit("MemberAdded",
		"address", addr.String(),
		"roles", roles,
	)
}

// RemoveMember removes an address from the membership. Only the owner can call this.
func RemoveMember(cur realm, addr address) {
	assertCallerIsOwner()
	if addr == owner {
		panic("cannot remove owner")
	}
	if _, exists := members.Get(addr.String()); !exists {
		panic("address is not a member: " + addr.String())
	}
	members.Remove(addr.String())

	chain.Emit("MemberRemoved", "address", addr.String())
}

// UpdateMemberRoles updates the roles for an existing member. Only the owner can call this.
func UpdateMemberRoles(cur realm, addr address, newRoles string) {
	assertCallerIsOwner()
	if _, exists := members.Get(addr.String()); !exists {
		panic("address is not a member: " + addr.String())
	}
	if len(newRoles) == 0 {
		panic("roles cannot be empty")
	}
	if !isValidRoles(newRoles) {
		panic("invalid roles: must be comma-separated alphanumeric only")
	}
	members.Set(addr.String(), newRoles)

	chain.Emit("MemberRolesUpdated", "address", addr.String(), "roles", newRoles)
}

// TransferOwnership transfers realm ownership to a new address. Only the current owner can call this.
// The new owner gets "admin" added to their existing roles (not overwritten).
// The old owner is demoted from "admin" to "member".
func TransferOwnership(cur realm, newOwner address) {
	assertCallerIsOwner()
	if newOwner == "" {
		panic("address cannot be empty")
	}
	if newOwner == owner {
		panic("new owner is the same as current owner")
	}
	prevOwner := owner
	// Preserve existing roles for new owner, ensure they have admin
	existingRoles := GetMemberRoles(newOwner)
	if existingRoles == "" {
		members.Set(newOwner.String(), "admin")
	} else if !hasRole(newOwner, "admin") {
		members.Set(newOwner.String(), existingRoles+",admin")
	}
	// Remove "admin" from old owner's roles, keep other roles.
	// If no roles remain, set to "member".
	oldRoles := GetMemberRoles(owner)
	var kept []string
	for _, r := range strings.Split(oldRoles, ",") {
		r = strings.TrimSpace(r)
		if r != "admin" && r != "" {
			kept = append(kept, r)
		}
	}
	if len(kept) == 0 {
		members.Set(owner.String(), "member")
	} else {
		members.Set(owner.String(), strings.Join(kept, ","))
	}
	owner = newOwner

	chain.Emit("OwnershipTransferred",
		"previousOwner", prevOwner.String(),
		"newOwner", newOwner.String(),
	)
}

// SyncMembers allows the owner to batch-sync membership from the DAO.
// addresses and rolesList are comma-separated, with roles pipe-delimited per address.
// Example: SyncMembers("g1a,g1b", "admin,dev|member")
func SyncMembers(cur realm, addresses string, rolesList string) {
	assertCallerIsOwner()
	addrs := strings.Split(addresses, ",")
	roles := strings.Split(rolesList, "|")
	if len(addrs) != len(roles) {
		panic("addresses and roles count mismatch")
	}
	synced := 0
	for i, addr := range addrs {
		addr = strings.TrimSpace(addr)
		if addr == "" {
			continue
		}
		role := strings.TrimSpace(roles[i])
		if !isValidRoles(role) {
			panic("invalid roles in entry " + strconv.Itoa(i))
		}
		members.Set(addr, role)
		synced++
	}

	chain.Emit("MembersSynced", "count", strconv.Itoa(synced))
}

// PurgeNonMembers removes all members not in the provided comma-separated list.
// The owner is never purged.
func PurgeNonMembers(cur realm, keepAddresses string) {
	assertCallerIsOwner()
	keep := make(map[string]bool)
	for _, addr := range strings.Split(keepAddresses, ",") {
		keep[strings.TrimSpace(addr)] = true
	}
	keep[owner.String()] = true // owner is never purged
	var toRemove []string
	members.Iterate("", "", func(key string, _ interface{}) bool {
		if !keep[key] {
			toRemove = append(toRemove, key)
		}
		return false
	})
	for _, addr := range toRemove {
		members.Remove(addr)
	}

	chain.Emit("MembersPurged", "count", strconv.Itoa(len(toRemove)))
}

// IsMember returns whether an address is a member.
func IsMember(addr address) bool {
	_, exists := members.Get(addr.String())
	return exists
}

// GetMemberRoles returns the roles for a member (comma-separated) or empty string.
func GetMemberRoles(addr address) string {
	val, exists := members.Get(addr.String())
	if !exists {
		return ""
	}
	return val.(string)
}

// GetOwner returns the current realm owner address.
func GetOwner() address {
	return owner
}

// ── Emergency Pause ────────────────────────────────────────
//
// Pause policy (AAA-1 B3 — one policy, enforced everywhere):
//   While paused, every member-facing content write is blocked via
//   assertNotPaused() — PostThread, PostReply, EditThread, DeleteThread/Reply,
//   FlagThread, RemoveThread/Reply, and SweepTombstones.
//
//   Owner-only governance (AddMember/RemoveMember/UpdateMemberRoles/SyncMembers/
//   PurgeNonMembers/TransferOwnership/CreateChannel) is intentionally NOT gated:
//   pause halts user activity during an incident, but the owner must stay able to
//   fix membership/ownership while paused. This realm holds no funds, so there is
//   no value-exit exemption to carve out.

func assertNotPaused() {
	if paused {
		panic("realm is paused — emergency maintenance")
	}
}

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

// ── Channel Management ───────────────────────────────────────

// CreateChannel adds a new channel. Only the owner (admin) can create channels.
func CreateChannel(cur realm, name, description string, ctype string) {
	assertCallerIsOwner()

	if len(channelOrder) >= MaxChannels {
		panic(ufmt.Sprintf("max channels reached: %d", MaxChannels))
	}
	if _, exists := channels.Get(name); exists {
		panic("channel already exists: " + name)
	}
	if !isValidChannelName(name) {
		panic("invalid channel name: must be 1-50 lowercase alphanumeric characters or hyphens, no leading underscore")
	}

	ct := ChannelText
	switch ctype {
	case "announcements":
		ct = ChannelAnnouncements
	case "readonly":
		ct = ChannelReadonly
	}

	addChannel(name, description, ct,
		[]string{"admin", "dev", "ops", "member"},
		[]string{"admin", "dev", "ops", "member"})

	chain.Emit("ChannelCreated", "name", name, "type", string(ct))
}

// ── Post Management ─────────────────────────────────────────

// PostThread creates a new thread in a channel.
// Caller must be a member with a role listed in the channel's WriteRoles.
func PostThread(cur realm, channel, title, body string) uint64 {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	// Validate membership and channel write access
	ch := getChannel(channel)
	assertCallerHasWriteAccess(caller, ch)
	if ch.Archived {
		panic("channel is archived")
	}
	// Cap on LIVE (non-deleted) threads so deleted threads free up slots.
	if getLiveThreadCount(channel) >= MaxThreadsPerChan {
		panic(ufmt.Sprintf("channel live thread limit reached: %d — delete old threads to make room", MaxThreadsPerChan))
	}
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic(ufmt.Sprintf("title must be 1-%d characters", MaxTitleLen))
	}
	if len(body) > MaxPostLen {
		panic(ufmt.Sprintf("body too long: %d/%d chars", len(body), MaxPostLen))
	}

	// Get next ID
	nextID := getThreadCount(channel)
	key := channel + "/" + strconv.FormatUint(nextID, 10)

	t := &Thread{
		ID:      nextID,
		Channel: channel,
		Title:   title,
		Body:    body,
		Author:  caller,
		BlockH:  runtime.ChainHeight(),
	}
	threads.Set(key, t)
	threadCount.Set(channel, nextID+1)
	threadLive.Set(channel, getLiveThreadCount(channel)+1)
	addLiveThreadID(channel, nextID)
	replyCount.Set(key, uint64(0))

	chain.Emit("ThreadPosted",
		"channel", channel,
		"threadId", strconv.FormatUint(nextID, 10),
		"author", caller.String(),
	)

	return nextID
}

// PostReply adds a reply to a thread.
// Caller must be a member with a role listed in the channel's WriteRoles.
func PostReply(cur realm, channel string, threadID uint64, body string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()

	// Validate membership and channel write access
	ch := getChannel(channel)
	assertCallerHasWriteAccess(caller, ch)

	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	tval, texists := threads.Get(threadKey)
	if !texists {
		panic("thread not found")
	}
	thread := tval.(*Thread)
	if thread.Deleted {
		panic("cannot reply to a deleted thread")
	}
	if thread.Hidden {
		panic("cannot reply to a hidden thread")
	}

	if len(body) == 0 || len(body) > MaxPostLen {
		panic(ufmt.Sprintf("reply must be 1-%d characters", MaxPostLen))
	}

	// B1: bound the LIVE reply set so renderThread stays under the gas budget.
	// Deleting replies frees slots (mirrors MaxThreadsPerChan / getLiveThreadCount).
	if getLiveReplyCount(threadKey) >= MaxRepliesPerThread {
		panic(ufmt.Sprintf("thread reply limit reached: %d — older replies must be removed", MaxRepliesPerThread))
	}

	nextReplyID := getReplyCount(threadKey)
	replyKey := threadKey + "/" + strconv.FormatUint(nextReplyID, 10)

	r := &Reply{
		ID:       nextReplyID,
		ThreadID: threadID,
		Channel:  channel,
		Body:     body,
		Author:   caller,
		BlockH:   runtime.ChainHeight(),
	}
	replies.Set(replyKey, r)
	replyCount.Set(threadKey, nextReplyID+1)
	// Track the live reply so renderThread iterates only live IDs (bounded set),
	// never the monotonic counter.
	addLiveReplyID(threadKey, nextReplyID)
	replyLive.Set(threadKey, getLiveReplyCount(threadKey)+1)

	chain.Emit("ReplyPosted",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"replyId", strconv.FormatUint(nextReplyID, 10),
		"author", caller.String(),
	)
}

// dropReply hard-removes a reply: deletes the node (storage reclaimed — B2),
// drops it from the live index, and decrements the live count. Shared by
// DeleteReply and RemoveReply. renderThread only walks the live index, so a
// removed reply is never looked up — no tombstone is needed.
func dropReply(threadKey, replyKey string, replyID uint64) {
	replies.Remove(replyKey)
	removeLiveReplyID(threadKey, replyID)
	if live := getLiveReplyCount(threadKey); live > 0 {
		replyLive.Set(threadKey, live-1)
	}
}

// DeleteReply lets the reply's author delete it. Caller must be a member and the
// original author. The reply node is hard-removed (B2 state-shrink) and a slot is
// freed under MaxRepliesPerThread (B1).
func DeleteReply(cur realm, channel string, threadID, replyID uint64) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	assertCallerIsMember(caller)

	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	replyKey := threadKey + "/" + strconv.FormatUint(replyID, 10)
	rval, exists := replies.Get(replyKey)
	if !exists {
		panic("reply not found")
	}
	if rval.(*Reply).Author != caller {
		panic("only the author can delete")
	}

	dropReply(threadKey, replyKey, replyID)

	chain.Emit("ReplyDeleted",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"replyId", strconv.FormatUint(replyID, 10),
		"author", caller.String(),
	)
}

// RemoveReply permanently removes a reply (moderation — admin role only). Hard-
// removes the node like DeleteReply, bounding renderThread (B1) + reclaiming
// storage (B2).
func RemoveReply(cur realm, channel string, threadID, replyID uint64) {
	assertCallerIsAdminRole()
	caller := unsafe.PreviousRealm().Address()

	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	replyKey := threadKey + "/" + strconv.FormatUint(replyID, 10)
	if _, exists := replies.Get(replyKey); !exists {
		panic("reply not found")
	}

	dropReply(threadKey, replyKey, replyID)

	chain.Emit("ReplyRemoved",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"replyId", strconv.FormatUint(replyID, 10),
		"admin", caller.String(),
	)
}

// EditThread allows the original author to edit their thread. Caller must be a member.
func EditThread(cur realm, channel string, threadID uint64, newBody string) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	assertCallerIsMember(caller)

	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	val, exists := threads.Get(threadKey)
	if !exists {
		panic("thread not found")
	}

	t := val.(*Thread)
	if t.Author != caller {
		panic("only the author can edit")
	}
	if t.Deleted {
		panic("cannot edit a deleted thread")
	}
	if t.Hidden {
		panic("cannot edit a hidden thread")
	}
	if len(newBody) > MaxPostLen {
		panic("body too long")
	}

	t.Body = newBody
	t.Edited = true
	t.EditedAt = runtime.ChainHeight()
	threads.Set(threadKey, t)

	chain.Emit("ThreadEdited",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"author", caller.String(),
	)
}

// DeleteThread soft-deletes a thread (marks as deleted). Caller must be a member and the original author.
func DeleteThread(cur realm, channel string, threadID uint64) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	assertCallerIsMember(caller)

	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	val, exists := threads.Get(threadKey)
	if !exists {
		panic("thread not found")
	}

	t := val.(*Thread)
	if t.Author != caller {
		panic("only the author can delete")
	}
	if t.Deleted {
		panic("thread already deleted")
	}

	t.Deleted = true
	t.Title = "[Deleted]"
	t.Body = ""
	threads.Set(threadKey, t)
	// Free a slot for new threads
	live := getLiveThreadCount(channel)
	if live > 0 {
		threadLive.Set(channel, live-1)
	}
	removeLiveThreadID(channel, threadID)
	enqueueThreadTomb(channel, threadID) // B2: queue for hard-GC via SweepTombstones

	chain.Emit("ThreadDeleted",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"author", caller.String(),
	)
}

// ── Moderation ──────────────────────────────────────────────

// FlagThread flags a thread for moderation review.
// After FlagThreshold flags, the thread is auto-hidden.
// Caller must be a member (any role) to flag content.
func FlagThread(cur realm, channel string, threadID uint64) {
	assertNotPaused()
	caller := unsafe.PreviousRealm().Address()
	assertCallerIsMember(caller)
	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)

	val, exists := threads.Get(threadKey)
	if !exists {
		panic("thread not found")
	}

	t := val.(*Thread)
	if t.Deleted {
		panic("cannot flag a deleted thread")
	}
	if t.Hidden {
		panic("thread is already hidden")
	}

	// Track unique flaggers
	var flagTree *avl.Tree
	if fval, fexists := flags.Get(threadKey); fexists {
		flagTree = fval.(*avl.Tree)
	} else {
		flagTree = avl.NewTree()
	}

	if _, already := flagTree.Get(caller.String()); already {
		panic("already flagged")
	}
	flagTree.Set(caller.String(), true)
	flags.Set(threadKey, flagTree)

	// Update thread flag count and auto-hide.
	// Dynamic threshold: max(FlagThreshold, 5% of members), scales with DAO size.
	t.FlagCount = flagTree.Size()
	dynamicThreshold := FlagThreshold
	fivePct := members.Size() / 20
	if fivePct > dynamicThreshold {
		dynamicThreshold = fivePct
	}
	wasHidden := t.Hidden
	if t.FlagCount >= dynamicThreshold {
		t.Hidden = true
	}
	threads.Set(threadKey, t)

	chain.Emit("ThreadFlagged",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"flagger", caller.String(),
		"flagCount", strconv.Itoa(t.FlagCount),
	)
	if !wasHidden && t.Hidden {
		chain.Emit("ThreadAutoHidden",
			"channel", channel,
			"threadId", strconv.FormatUint(threadID, 10),
		)
	}
}

// UnhideThread allows the owner or an admin to clear flags and un-hide a thread.
func UnhideThread(cur realm, channel string, threadID uint64) {
	assertCallerIsAdminRole()
	caller := unsafe.PreviousRealm().Address()
	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)

	val, exists := threads.Get(threadKey)
	if !exists {
		panic("thread not found")
	}
	t := val.(*Thread)
	t.Hidden = false
	t.FlagCount = 0
	threads.Set(threadKey, t)
	// Clear flag tree
	flags.Remove(threadKey)

	chain.Emit("ThreadUnhidden",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"admin", caller.String(),
	)
}

// RemoveThread permanently removes a thread (moderation action — admin role only).
func RemoveThread(cur realm, channel string, threadID uint64) {
	assertCallerIsAdminRole()
	caller := unsafe.PreviousRealm().Address()
	threadKey := channel + "/" + strconv.FormatUint(threadID, 10)
	val, exists := threads.Get(threadKey)
	if !exists {
		panic("thread not found")
	}

	t := val.(*Thread)
	if !t.Deleted {
		live := getLiveThreadCount(channel)
		if live > 0 {
			threadLive.Set(channel, live-1)
		}
		removeLiveThreadID(channel, threadID)
		enqueueThreadTomb(channel, threadID) // B2: queue for hard-GC (skip if already tombstoned)
	}
	t.Deleted = true
	t.Hidden = true
	t.Title = "[Removed by moderation]"
	t.Body = ""
	threads.Set(threadKey, t)

	chain.Emit("ThreadRemoved",
		"channel", channel,
		"threadId", strconv.FormatUint(threadID, 10),
		"admin", caller.String(),
	)
}

// SweepTombstones hard-removes up to `limit` soft-deleted threads in a channel
// (and all of their remaining reply state), reclaiming AVL storage so that
// post+delete spam can no longer accrete permanent state (B2).
//
// Permissionless GC by design: anyone may call it. Released storage deposits go
// to the calling tx per the chain's deposit policy (an explicit caller bounty);
// on restricted-denom chains (e.g. test12/test13 `restricted_denoms=["ugnot"]`)
// they route to the StorageFeeCollector instead — so this is a state-shrink/
// hygiene primitive, not a user-refund path (see plan B2 / Q11).
//
// Bounded + idempotent: each soft-deleted thread holds at most
// MaxRepliesPerThread reply nodes, so keep `limit` small (1–5) to stay well
// within block gas; re-running drains the next batch and stops at 0.
// Returns the number of threads swept.
func SweepTombstones(cur realm, channel string, limit int) int {
	assertNotPaused()
	if limit <= 0 {
		return 0
	}

	tomb := getThreadTomb(channel)
	n := limit
	if n > len(tomb) {
		n = len(tomb)
	}

	for i := 0; i < n; i++ {
		threadKey := channel + "/" + strconv.FormatUint(tomb[i], 10)
		// Collect-then-remove: read the live reply IDs (a stored slice) and remove
		// each reply node — we never iterate the tree we mutate (AVL footgun).
		for _, rid := range getLiveReplyIDs(threadKey) {
			replies.Remove(threadKey + "/" + strconv.FormatUint(rid, 10))
		}
		replyLiveIDs.Remove(threadKey)
		replyLive.Remove(threadKey)
		replyCount.Remove(threadKey)
		flags.Remove(threadKey)
		threads.Remove(threadKey)
	}

	// Drop the processed prefix; copy the tail into a fresh slice to avoid aliasing.
	remaining := append([]uint64{}, tomb[n:]...)
	if len(remaining) == 0 {
		threadTomb.Remove(channel)
	} else {
		threadTomb.Set(channel, remaining)
	}

	if n > 0 {
		chain.Emit("TombstonesSwept",
			"channel", channel,
			"count", strconv.Itoa(n),
		)
	}
	return n
}

// GetTombstoneCount returns how many soft-deleted threads in a channel are still
// awaiting hard-GC (read-only; lets ops/indexers decide when to call SweepTombstones).
func GetTombstoneCount(channel string) int {
	return len(getThreadTomb(channel))
}

// ── Render ───────────────────────────────────────────────────
// CRITICAL: Output format MUST match parser.ts regex patterns.

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "__acl/") {
		channelName := strings.TrimPrefix(path, "__acl/")
		return renderACL(channelName)
	}
	if strings.HasPrefix(path, "__member/") {
		addr := strings.TrimPrefix(path, "__member/")
		roles := GetMemberRoles(address(addr))
		if roles == "" {
			return "not found"
		}
		return "roles:" + roles
	}
	if strings.HasPrefix(path, "_channel/") {
		channelName := strings.TrimPrefix(path, "_channel/")
		return renderChannel(channelName)
	}

	// Check for "channel/threadId" pattern, optionally with a "?page=N" suffix
	// for reply pagination (B1).
	parts := strings.SplitN(path, "/", 2)
	if len(parts) == 2 {
		idPart := parts[1]
		page := uint64(0)
		if qi := strings.IndexByte(idPart, '?'); qi >= 0 {
			page = parsePageQuery(idPart[qi+1:])
			idPart = idPart[:qi]
		}
		threadID, err := strconv.ParseUint(idPart, 10, 64)
		if err == nil {
			return renderThread(parts[0], threadID, page)
		}
	}

	// Try as channel name directly
	if _, exists := channels.Get(path); exists {
		return renderChannel(path)
	}

	return "# 404\nPage not found: " + path
}

// renderHome produces the board home page.
// Format: parser.ts parseBoardHome() expects:
//   - [#name](:_channel/name) 📢 (N threads)
func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# MembaDAO Channels\n\n")
	sb.WriteString("Community discussion channels for the Memba ecosystem.\n\n")
	sb.WriteString(ufmt.Sprintf("**Owner:** %s | **Members:** %d\n\n", owner, members.Size()))
	sb.WriteString("## Channels\n\n")

	for _, name := range channelOrder {
		val, exists := channels.Get(name)
		if !exists {
			continue
		}
		ch := val.(*Channel)
		if ch.Archived {
			continue
		}

		count := getThreadCount(name)
		typeIcon := ""
		switch ch.Type {
		case ChannelAnnouncements:
			typeIcon = " 📢"
		case ChannelReadonly:
			typeIcon = " 🔒"
		}

		sb.WriteString(ufmt.Sprintf("- [#%s](:_channel/%s)%s (%d threads)\n",
			name, name, typeIcon, count))
	}

	return sb.String()
}

// renderChannel produces a channel's thread list.
// Format: parser.ts parseThreadList() expects:
//   ### [Title](:channel/id)
//   by g1addr... | N replies | block H
func renderChannel(channelName string) string {
	if _, exists := channels.Get(channelName); !exists {
		return "# 404\nChannel not found: " + channelName
	}

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# #%s\n\n", channelName))

	// Iterate the LIVE thread-ID index (bounded by getLiveThreadCount), newest
	// first. Never loop over the monotonic threadCount — a post+delete spam
	// loop inflates it without bound (gas DoS); deleted IDs are not in this index.
	ids := getLiveThreadIDs(channelName)
	if len(ids) == 0 {
		sb.WriteString("*No threads yet. Be the first to post!*\n")
		return sb.String()
	}

	for i := len(ids) - 1; i >= 0; i-- {
		threadKey := channelName + "/" + strconv.FormatUint(ids[i], 10)
		val, exists := threads.Get(threadKey)
		if !exists {
			continue
		}
		t := val.(*Thread)
		if t.Hidden || t.Deleted {
			continue
		}

		// Count live (non-deleted) replies — matches what renderThread shows.
		rCount := getLiveReplyCount(threadKey)
		authorStr := truncAddr(t.Author)

		sb.WriteString(ufmt.Sprintf("### [%s](:%s/%d)\n", sanitizeForRender(t.Title), channelName, t.ID))
		sb.WriteString(ufmt.Sprintf("by %s | %d replies | block %d\n\n", authorStr, rCount, t.BlockH))
	}

	return sb.String()
}

// renderThread produces a single thread with replies.
// Format: parser.ts parseThreadDetail() expects:
//   # Title
//   body
//   ---
//   *Posted by g1addr at block H* *(edited at block M)*
//   ## Replies
//   **g1addr...** (block H) *(edited)*
//   reply body
//   ---
func renderThread(channelName string, threadID, page uint64) string {
	threadKey := channelName + "/" + strconv.FormatUint(threadID, 10)
	val, exists := threads.Get(threadKey)
	if !exists {
		return "# 404\nThread not found"
	}

	t := val.(*Thread)

	// Suppress content for hidden (flag-auto-hidden or admin-hidden) and
	// soft-deleted threads. renderChannel omits these from the list, but the
	// direct path Render("channel/id") must not leak the original title/body.
	if t.Hidden || t.Deleted {
		return "# Thread unavailable\n\n*This thread has been hidden or removed.*\n"
	}

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# %s\n\n", sanitizeForRender(t.Title)))
	sb.WriteString(sanitizeForRender(t.Body) + "\n\n")
	sb.WriteString("---\n\n")
	sb.WriteString(ufmt.Sprintf("*Posted by %s at block %d*", string(t.Author), t.BlockH))
	if t.Edited {
		sb.WriteString(ufmt.Sprintf(" *(edited at block %d)*", t.EditedAt))
	}
	sb.WriteString("\n\n")

	// B1: render only LIVE replies (bounded by MaxRepliesPerThread), paginated to
	// a fixed window so render cost is O(ReplyPageSize) regardless of total churn.
	// Never iterate the monotonic replyCount — that is the render-DoS surface.
	liveIDs := getLiveReplyIDs(threadKey) // ascending (oldest→newest), <= MaxRepliesPerThread
	total := uint64(len(liveIDs))
	if total > 0 {
		totalPages := (total + ReplyPageSize - 1) / ReplyPageSize
		// page 1 = oldest window … totalPages = newest. Default (0) and any
		// out-of-range value snap to the newest page (most-recent replies).
		if page == 0 || page > totalPages {
			page = totalPages
		}
		start := (page - 1) * ReplyPageSize
		end := start + ReplyPageSize
		if end > total {
			end = total
		}

		sb.WriteString("## Replies\n\n")
		if totalPages > 1 {
			sb.WriteString(ufmt.Sprintf(
				"*Showing %d–%d of %d • page %d/%d — older: `?page=%d`, newer: `?page=%d`*\n\n",
				start+1, end, total, page, totalPages, pageClamp(page-1, totalPages), pageClamp(page+1, totalPages)))
		}

		for i := start; i < end; i++ {
			replyKey := threadKey + "/" + strconv.FormatUint(liveIDs[i], 10)
			rval, rexists := replies.Get(replyKey)
			if !rexists {
				continue // live index never points at a removed reply, but stay safe
			}
			r := rval.(*Reply)
			authorStr := truncAddr(r.Author)
			editStr := ""
			if r.Edited {
				editStr = " *(edited)*"
			}
			sb.WriteString(ufmt.Sprintf("**%s** (block %d)%s\n\n", authorStr, r.BlockH, editStr))
			sb.WriteString(sanitizeForRender(r.Body) + "\n\n")
			sb.WriteString("---\n\n")
		}
	}

	return sb.String()
}

// parsePageQuery extracts the page number from a "?page=N" query string (also
// tolerates extra &-separated params). Returns 0 (= default/newest) on absence
// or parse error.
func parsePageQuery(q string) uint64 {
	for _, kv := range strings.Split(q, "&") {
		if strings.HasPrefix(kv, "page=") {
			if n, err := strconv.ParseUint(strings.TrimPrefix(kv, "page="), 10, 64); err == nil {
				return n
			}
		}
	}
	return 0
}

// pageClamp keeps a page link within [1, totalPages].
func pageClamp(p, totalPages uint64) uint64 {
	if p < 1 {
		return 1
	}
	if p > totalPages {
		return totalPages
	}
	return p
}

// renderACL produces the ACL response for a channel.
// Format: parser.ts parseACL() expects:
//   read:role1,role2
//   write:role1,role2,role3
//   type:text
func renderACL(channelName string) string {
	val, exists := channels.Get(channelName)
	if !exists {
		return "not found"
	}
	ch := val.(*Channel)

	var sb strings.Builder
	sb.WriteString("read:" + strings.Join(ch.ReadRoles, ",") + "\n")
	sb.WriteString("write:" + strings.Join(ch.WriteRoles, ",") + "\n")
	sb.WriteString("type:" + string(ch.Type) + "\n")

	return sb.String()
}

// ── Helpers ──────────────────────────────────────────────────

func getChannel(name string) *Channel {
	val, exists := channels.Get(name)
	if !exists {
		panic("channel not found: " + name)
	}
	return val.(*Channel)
}

func getThreadCount(channel string) uint64 {
	val, exists := threadCount.Get(channel)
	if !exists {
		return 0
	}
	return val.(uint64)
}

// getLiveThreadCount returns the number of non-deleted threads in a channel.
// Unlike getThreadCount (monotonic ID counter), this decreases when threads
// are deleted, so deleted threads free up slots under MaxThreadsPerChan.
func getLiveThreadCount(channel string) uint64 {
	val, exists := threadLive.Get(channel)
	if !exists {
		return 0
	}
	return val.(uint64)
}

// ── Live thread-ID index ─────────────────────────────────────
// renderChannel must iterate only live (non-deleted) thread IDs, never the
// monotonic threadCount: a member can post+delete in a loop to inflate
// threadCount without bound (the live cap only limits live threads), turning
// renderChannel into an unbounded O(threadCount) scan (gas DoS). This index
// stays bounded by getLiveThreadCount (<= MaxThreadsPerChan).

func getLiveThreadIDs(channel string) []uint64 {
	if val, exists := threadLiveIDs.Get(channel); exists {
		return val.([]uint64)
	}
	return nil
}

func addLiveThreadID(channel string, id uint64) {
	threadLiveIDs.Set(channel, append(getLiveThreadIDs(channel), id))
}

func removeLiveThreadID(channel string, id uint64) {
	ids := getLiveThreadIDs(channel)
	for i, x := range ids {
		if x == id {
			threadLiveIDs.Set(channel, append(ids[:i], ids[i+1:]...))
			return
		}
	}
}

// ── Live reply-ID index ──────────────────────────────────────
// Same rationale as the thread index, one level down: renderThread must iterate
// only live reply IDs (bounded by MaxRepliesPerThread), never the monotonic
// replyCount, or a member can post+delete replies in a loop to make a thread
// unrenderable. Keyed by "channel/threadId".

func getLiveReplyCount(threadKey string) uint64 {
	if val, exists := replyLive.Get(threadKey); exists {
		return val.(uint64)
	}
	return 0
}

func getLiveReplyIDs(threadKey string) []uint64 {
	if val, exists := replyLiveIDs.Get(threadKey); exists {
		return val.([]uint64)
	}
	return nil
}

func addLiveReplyID(threadKey string, id uint64) {
	replyLiveIDs.Set(threadKey, append(getLiveReplyIDs(threadKey), id))
}

func removeLiveReplyID(threadKey string, id uint64) {
	ids := getLiveReplyIDs(threadKey)
	for i, x := range ids {
		if x == id {
			replyLiveIDs.Set(threadKey, append(ids[:i], ids[i+1:]...))
			return
		}
	}
}

// ── Thread tombstone queue (B2 hard-GC) ──────────────────────
// Soft-deleted thread IDs awaiting permanent removal by SweepTombstones. A queue
// (not a scan of the threads tree) keeps the sweep O(limit) — it never walks the
// unbounded set of past tombstones.

func getThreadTomb(channel string) []uint64 {
	if val, exists := threadTomb.Get(channel); exists {
		return val.([]uint64)
	}
	return nil
}

func enqueueThreadTomb(channel string, id uint64) {
	threadTomb.Set(channel, append(getThreadTomb(channel), id))
}

func getReplyCount(threadKey string) uint64 {
	val, exists := replyCount.Get(threadKey)
	if !exists {
		return 0
	}
	return val.(uint64)
}

func truncAddr(addr address) string {
	s := string(addr)
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

// isValidRoles validates a comma-separated role list contains only safe characters.
// Allowed: a-z, A-Z, 0-9, hyphen, comma. No spaces, no markdown chars, no null bytes.
func isValidRoles(s string) bool {
	if len(s) > 200 {
		return false
	}
	for _, c := range s {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == ',') {
			return false
		}
	}
	return true
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

// ── ACL Enforcement ─────────────────────────────────────────

func assertCallerIsOwner() {
	caller := unsafe.PreviousRealm().Address()
	if caller != owner {
		panic("unauthorized: caller " + caller.String() + " is not the owner")
	}
}

func assertCallerIsMember(caller address) {
	if _, exists := members.Get(caller.String()); !exists {
		panic("unauthorized: caller " + caller.String() + " is not a member")
	}
}

// assertCallerHasWriteAccess checks that the caller is a member AND has at least
// one role that matches the channel's WriteRoles.
func assertCallerHasWriteAccess(caller address, ch *Channel) {
	rolesStr, exists := members.Get(caller.String())
	if !exists {
		panic("unauthorized: caller " + caller.String() + " is not a member")
	}

	callerRoles := strings.Split(rolesStr.(string), ",")
	for _, cr := range callerRoles {
		cr = strings.TrimSpace(cr)
		for _, wr := range ch.WriteRoles {
			if cr == wr {
				return // Access granted
			}
		}
	}

	panic("unauthorized: caller " + caller.String() + " lacks write access to channel " + ch.Name)
}

func hasRole(caller address, role string) bool {
	rolesStr, exists := members.Get(caller.String())
	if !exists {
		return false
	}
	callerRoles := strings.Split(rolesStr.(string), ",")
	for _, cr := range callerRoles {
		if strings.TrimSpace(cr) == role {
			return true
		}
	}
	return false
}

// assertCallerIsAdminRole checks that the caller is a member with the "admin" role.
// Used for moderation actions (RemoveThread, UnhideThread) so any admin can moderate,
// not just the single owner.
func assertCallerIsAdminRole() {
	caller := unsafe.PreviousRealm().Address()
	if !hasRole(caller, "admin") {
		panic("unauthorized: caller " + caller.String() + " does not have admin role")
	}
}

// isValidChannelName validates that a channel name contains only
// lowercase alphanumeric characters and hyphens, and does not start with underscore.
func isValidChannelName(name string) bool {
	if len(name) == 0 || len(name) > 50 {
		return false
	}
	if name[0] == '_' {
		return false // Prevent collision with __acl/, __member/ paths
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
			return false
		}
	}
	return true
}
