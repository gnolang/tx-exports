// Package chat is the SPLASH arcade's room: a bounded, append-only ring of
// public messages, posted by anyone with a wallet and readable by anyone at
// all.
//
// IT EXISTS BECAUSE SETTLEMENT IS A SHARED MOMENT. Duels pin a future drand
// round and many of them land on the SAME round — the bucketing in
// arcade/duel is deliberate about that. A dozen people watching one number
// arrive is the thing worth being in a room for. Without somewhere to say so
// it is a dozen people each alone with a spinner.
//
// WHAT THIS REALM DELIBERATELY DOES NOT HAVE, and why each absence is a
// decision rather than an omission:
//
//   - NO ADMIN, NO OWNER, NO DELETE, NO EDIT. Not "not yet" — there is no
//     address anywhere in this file with a power no other address has. The
//     rules page promises "no admin over your money" and "nobody can pause,
//     delay or refuse"; a moderator key over other people's words is the same
//     promise broken in a different column. Ruled by the owner 2026-10-08
//     after being shown the trade explicitly: the alternative was a key that
//     could remove messages, and he chose not to have one.
//
//   - NO MONEY. This realm holds no coin, has no allowance, makes no
//     transfer and imports no token. It cannot lose funds because it never
//     has any. That is most of its security argument and it is why the whole
//     file is this short.
//
//     THAT INVARIANT NEEDS AN ACTIVE GUARD, NOT JUST THE ABSENCE OF CODE, and
//     the first draft of this file got that wrong. A realm receives native
//     coin whether or not it has any code to do so: `maketx call --send
//     1000000ugnot -func Post` credits this realm's address at the chain
//     root, and Post would have succeeded and kept it. With no banker, no
//     owner and no withdraw — all deliberate, all permanent, because a realm
//     cannot be upgraded — that coin would be destroyed rather than merely
//     stuck. Hence rejectAttachedCoin below, which is the same guard the
//     other four SPLASH realms have carried since 2026-10-07. Caught by audit
//     before deployment, 2026-10-08.
//
//     THE GUARD COVERS Post AND NOTHING ELSE, and cannot be made to cover
//     more. Gno gives a realm no receive hook, so a plain `maketx send` to
//     this address, a wugnot transfer, or any other realm's banker can put
//     value here and no code anywhere could refuse it. The eight read
//     functions are non-crossing and so have no `cur` to check at all. What
//     the guard buys is the one case a normal user could hit by accident —
//     attaching coin to the call they actually meant to make. Everything
//     else burns the sender's own coin and harms nobody: this realm has no
//     accounting, reads no balance and pays nothing out, so stray value
//     cannot change any behaviour. Said plainly here so the next reader does
//     not mistake "guarded" for "impossible".
//
//   - NO REPLIES, NO THREADS, NO MENTIONS, NO REACTIONS. A flat room. Every
//     one of those is a second index, and a second index is a second thing
//     that can grow without bound.
//
// WHAT IT DOES HAVE, and the reasoning that is NOT obvious from the code:
//
//   - A FIXED-SIZE RING. Storage on a chain is paid for once and kept
//     forever. An unbounded log would make every future Post more expensive
//     than the last and eventually price the room shut. The ring overwrites;
//     Seen() reports the true total so nobody mistakes "the ring holds 64"
//     for "64 messages have ever been sent". The event log is the durable
//     record — see the chain.Emit in Post.
//
//   - A PER-ADDRESS COOLDOWN. THIS IS NOT MODERATION and the distinction
//     matters enough to state: it is a rule of arithmetic applied identically
//     to every address including ours, enforced by the contract, with no
//     human in the loop and no exceptions possible. It stops ONE WALLET
//     bursting and evicting the room in a single block, and that is all it
//     stops — 64 funded addresses still wipe the ring in a block or two, and
//     that is accepted. The exact arithmetic lives on cooldownBlocks and is
//     deliberately NOT repeated here: an earlier version stated it in both
//     places, the correction landed on one, and the false figure sat at the
//     top of the file where most readers meet it first. One claim, one home.
//     It cannot silence anybody — it only makes everyone wait the same
//     amount.
package chat

import (
	"strconv"
	"time"
	"unicode/utf8"

	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// maxTextLen is the cap on one message, in BYTES not runes — because
	// bytes are what storage costs and what len() measures. 280 bytes of
	// UTF-8 is roughly 280 Latin characters or ~93 emoji; the room is for
	// "GET IN", not for essays.
	maxTextLen = 280

	// ringSize is how many messages are readable at once. 64 is chosen
	// against the thing this room is FOR: a settlement bucket is 100 drand
	// rounds, i.e. five minutes, and a busy five minutes is tens of
	// messages, not hundreds. Large enough to hold a whole settlement,
	// small enough that the realm's storage never becomes a reason not to
	// post.
	ringSize = 64

	// cooldownBlocks is the minimum gap between two messages from the SAME
	// address. onyx blocks are ~3.3 seconds, so 2 blocks is ~7 seconds.
	//
	// IT IS DELIBERATELY SMALL. The job is to stop one wallet evicting the
	// ring in a single burst, NOT to pace conversation — a room where
	// replying feels slow is a room nobody uses, and the whole point is the
	// shared moment.
	//
	// WHAT THIS DOES AND DOES NOT BUY, stated precisely because the first
	// draft of this comment got the arithmetic wrong and would have misled
	// whoever next decided whether more was needed. It claimed flooding the
	// ring would cost cooldownBlocks x ringSize = 128 blocks, "hours, in
	// public". That is false. The cooldown is per address and is skipped
	// entirely for an address with no entry, so SIXTY-FOUR funded addresses
	// posting once each evict the whole room INSIDE ONE BLOCK. The real cost
	// of a wipe is 64 funded addresses, not 128 blocks.
	//
	// So: this stops a SINGLE WALLET bursting, and that is all it stops.
	// Buying the property the old comment described would need a global rate
	// limit, which is a different mechanism and a product decision nobody has
	// made. Sybil flooding by many addresses is accepted for a testnet room
	// with no money in it. Corrected after audit, 2026-10-08.
	cooldownBlocks = 2
)

// Message is one line in the room. Every field is set by the contract from
// the transaction itself EXCEPT Text, which is the only caller-supplied value
// in this realm — so Text is the only thing any reader has to treat as
// hostile. Author cannot be forged: it is read from the call, never from an
// argument.
type Message struct {
	ID     int64   // monotonic, never reused, survives ring eviction
	Author address // the EOA that signed; set by the contract, not the caller
	Text   string  // the ONLY caller-controlled field in this struct
	Height int64   // block it landed in
	Time   int64   // block timestamp, unix seconds
}

var (
	messages []Message // len is capped at ringSize
	next     int       // write cursor; wraps once full
	seen     int64     // total ever posted, including those overwritten

	// lastPost maps address -> block height of that address's last message,
	// and is the cooldown's whole state.
	//
	// THIS IS THE ONE UNBOUNDED STRUCTURE IN THE REALM, and that is a
	// considered trade rather than an oversight. It grows by one entry per
	// DISTINCT address that has ever posted, which is bounded by the number
	// of real participants, and each entry is an address and an int. It
	// cannot be made to grow faster than the cooldown allows: an attacker
	// buying entries with fresh addresses pays a transaction per entry and
	// gains nothing but a row. The alternative — storing the cooldown in the
	// ring and scanning it — would silently stop working the moment a
	// flooder's own messages rolled off the end, which is precisely when the
	// cooldown is needed.
	lastPost = avl.NewTree()
)

// --- Writing ---------------------------------------------------------------

// Post appends one message and returns its ID.
//
// It is a crossing function because it reads the caller's identity, and it
// requires an EOA: cur.Previous().IsUserCall(). A realm posting on a user's
// behalf would make Author meaningless — the room would show the realm's
// address for every line and there would be no way to tell who said what.
// There is no reason for a contract to speak here.
func Post(cur realm, text string) int64 {
	// FIRST, before the authorisation check — same ordering as ops.gno, so
	// that a caller who both attached coin and failed some other check is
	// told about the coin, which is the one that costs them money.
	rejectAttachedCoin(cur)
	if !cur.Previous().IsUserCall() {
		panic("chat: only a wallet can post, not a contract")
	}
	author := cur.Previous().Address()
	checkText(text)

	h := runtime.ChainHeight()
	key := string(author)
	if lastPost.Has(key) {
		prev := lastPost.Get(key).(int64)
		// Strictly-less comparison on the SUM, not a subtraction — these are
		// int64 block heights and cannot overflow in any reachable chain
		// lifetime, but the sum form says the intent without the reader
		// having to check for a negative difference.
		if h < prev+cooldownBlocks {
			panic("chat: too soon — wait " + strconv.FormatInt(prev+cooldownBlocks-h, 10) + " more block(s)")
		}
	}
	lastPost.Set(key, h)

	seen++
	m := Message{
		ID:     seen,
		Author: author,
		Text:   text,
		Height: h,
		// time.Now() IN A REALM IS BLOCK TIME, not wall clock — whole
		// seconds, identical for every call in the same block. It is the
		// same clock beacon/v2 uses to work out the current drand round,
		// which is what makes a message's timestamp comparable with the
		// round a duel is waiting on.
		Time: time.Now().Unix(),
	}
	if len(messages) < ringSize {
		messages = append(messages, m)
		next = len(messages) % ringSize
	} else {
		messages[next] = m
		next = (next + 1) % ringSize
	}

	// THE EVENT LOG IS THE DURABLE RECORD. The ring forgets; this does not,
	// and it is how a front end backfills past the 64 the realm will hand
	// it.
	//
	// THE TEXT HAS TO BE IN HERE. The first draft emitted id, author and
	// height only, which made the paragraph above false: a front end
	// following it would have got a list of ids with no messages. (The words
	// were not destroyed — they live in the transaction's calldata forever —
	// but recovering them by scanning transactions is a different and much
	// worse mechanism than the one this comment promises.) Caught by audit
	// before deployment, 2026-10-08.
	chain.Emit("Said",
		"id", strconv.FormatInt(m.ID, 10),
		"author", string(author),
		"height", strconv.FormatInt(h, 10),
		"text", m.Text,
	)
	return m.ID
}

// rejectAttachedCoin panics if the caller attached native coin. This realm has
// no use for any, and — unlike every other realm in SPLASH — no way whatsoever
// to give it back. See the note in the package comment.
//
// Inert on a non-user call, for the reason r/splash/exchange's Buy comment
// gives: unsafe.OriginSend() reads the envelope attached at the chain root,
// shared by every realm in the call chain, so reading it is only sound when
// the immediate caller is an EOA. Post refuses non-EOA callers on the very
// next line anyway, so nothing is let through by this early return.
func rejectAttachedCoin(cur realm) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if sent := unsafe.OriginSend(); len(sent) != 0 {
		panic("chat: posting does not take native coin — this realm cannot hold or return it")
	}
}

// checkText is the whole input policy, in one place so there is one answer to
// "what is allowed".
//
// Control characters are rejected rather than stripped, deliberately: a
// silent strip means the sender sees something different from the room, and
// a newline inside a markdown table cell would break every row below it in
// Render. Better to refuse and say why.
func checkText(text string) {
	if len(text) == 0 {
		panic("chat: say something")
	}
	if len(text) > maxTextLen {
		panic("chat: too long — " + strconv.Itoa(maxTextLen) + " bytes maximum")
	}
	if !utf8.ValidString(text) {
		panic("chat: not valid UTF-8")
	}
	for i := 0; i < len(text); i++ {
		if text[i] < 0x20 || text[i] == 0x7f {
			panic("chat: no control characters, including line breaks")
		}
	}
}

// --- Reading ---------------------------------------------------------------

// Count is how many messages the ring currently holds, at most RingSize.
func Count() int64 { return int64(len(messages)) }

// Seen is every message ever posted, including those the ring has
// overwritten. The gap between this and Count is exactly what a reader must
// go to the event log for.
func Seen() int64 { return seen }

// RingSize is the bound, exported so a front end can say "last 64" without
// hardcoding a number that might change.
func RingSize() int64 { return ringSize }

// MaxTextLen lets a front end enforce the same cap the contract will, so a
// too-long message is refused in the browser instead of costing gas to fail.
func MaxTextLen() int64 { return maxTextLen }

// CooldownBlocks lets a front end say how long the wait is instead of
// surprising someone with a panic.
func CooldownBlocks() int64 { return cooldownBlocks }

// NextAllowedHeight is the first block at which addr may post again, or 0 if
// addr has never posted. A front end can disable its button until then rather
// than letting someone pay gas to be refused.
func NextAllowedHeight(addr address) int64 {
	key := string(addr)
	if !lastPost.Has(key) {
		return 0
	}
	return lastPost.Get(key).(int64) + cooldownBlocks
}

// Recent returns up to `limit` messages, MOST RECENT FIRST. limit is clamped
// to what the ring holds, so no caller can ask for an unbounded amount of
// work.
func Recent(limit int64) []Message {
	n := int64(len(messages))
	if n == 0 {
		return []Message{}
	}
	if limit <= 0 || limit > n {
		limit = n
	}
	out := make([]Message, 0, limit)
	// next points at the oldest slot once the ring is full, so walk
	// backwards from the most recently written one.
	i := next - 1
	if i < 0 {
		i = len(messages) - 1
	}
	for c := int64(0); c < limit; c++ {
		out = append(out, messages[i])
		i--
		if i < 0 {
			i = len(messages) - 1
		}
	}
	return out
}

// --- Render ----------------------------------------------------------------
//
// IT MUST NEVER PANIC, WHATEVER path IS. A panicking Render does not fail
// quietly on one request — it takes the realm's whole gnoweb page down, for
// everyone, permanently, because a realm cannot be upgraded. So this ignores
// `path` entirely, reads only, and loops over a bounded collection.
//
// EVERY MESSAGE GOES THROUGH cell(). Text is free input from a stranger and
// this is a markdown document: unescaped, it can forge table rows, inject
// links, or impersonate the house.

func cell(s string) string {
	out := sanitize.InlineText(s)
	esc := ""
	for _, r := range out {
		if r == '|' {
			esc += "\\|"
			continue
		}
		esc += string(r)
	}
	return esc
}

func short(a address) string {
	s := string(a)
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func Render(path string) string {
	out := "# SPLASH — the room\n\n"
	// "Nobody can delete anything" was the first draft and it was not true
	// on its own page: the ring evicts the oldest message every time it
	// takes a new one past the bound. What is actually true is that nobody
	// can delete SELECTIVELY — there is no key that can remove one person's
	// words while leaving everyone else's.
	out += "Public, and nobody can pick out a message to remove — there is no "
	out += "moderator key on this contract, ours included. This page keeps the "
	out += "most recent " + strconv.Itoa(ringSize) + "; everything ever said is in the chain's "
	out += "own log and cannot be taken back.\n\n"
	out += "- holding: **" + strconv.FormatInt(Count(), 10) + "** of " + strconv.Itoa(ringSize) + "\n"
	out += "- said here, ever: **" + strconv.FormatInt(seen, 10) + "**\n\n"

	if len(messages) == 0 {
		out += "_Nobody has said anything yet._\n"
		return out
	}

	out += "| # | who | said | block |\n|---:|---|---|---:|\n"
	for _, m := range Recent(int64(len(messages))) {
		out += "| " + strconv.FormatInt(m.ID, 10) +
			" | `" + short(m.Author) + "`" +
			" | " + cell(m.Text) +
			" | " + strconv.FormatInt(m.Height, 10) + " |\n"
	}
	return out
}
