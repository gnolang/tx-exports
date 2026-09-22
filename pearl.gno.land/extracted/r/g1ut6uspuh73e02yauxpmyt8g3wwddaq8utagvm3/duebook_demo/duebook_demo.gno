// Package duebook_demo is the reference consumer for the duebook
// scheduling primitive. It exists to make duebook's central claim
// falsifiable on a live chain.
//
// That claim is: a deferral claimed in transaction N is refused in
// transaction N+1, forever. A pure package cannot demonstrate this — a
// vm/qeval is a single ephemeral evaluation with no state that survives
// it. Only a realm, called twice, can show it. So this realm is not a
// decoration on the primitive; it is the experiment.
//
// # What it does
//
// Anyone schedules an announcement to be published no earlier than
// delayBlocks from now. Once due, ANYONE may publish it — publication is
// deliberately permissionless, so that what protects the announcement from
// being published twice is duebook's exactly-once Claim and nothing else.
// If an access-control list were guarding Publish, the experiment would
// prove nothing about duebook.
//
// The scheduler may cancel at any time before publication. Once the
// optional time-to-live elapses, the announcement can never be published
// and anyone may clear it to free a slot.
//
// # How it wires duebook correctly
//
// This realm is also the worked example of duebook's consumer contract:
//
//   - the clock is runtime.ChainHeight(), never a call argument (contract 1);
//   - heights are the only unit used (contract 2);
//   - the *Book is an unexported package-level var and is never returned
//     across a realm boundary (contract 3);
//   - the owner is cur.Previous().Address(), never a parameter (contract 4);
//   - Publish performs its effect immediately after a successful Claim, in
//     the same transaction (contract 5).
//
// This realm holds no coins and has no admin. Every entrypoint rejects
// attached coins.
package duebook_demo

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/duebook"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// MinDelayBlocks is the floor on how far ahead an announcement may be
	// scheduled. One block is enough to prove the delay is enforced while
	// keeping the realm exercisable on a live chain.
	MinDelayBlocks = int64(1)

	// MaxDelayBlocks caps scheduling roughly 100 days out at pearl-1's
	// ~3.42s blocks. It also bounds now+delay well inside int64.
	MaxDelayBlocks = int64(2_500_000)

	// MaxTTLBlocks caps how long a due announcement stays publishable.
	MaxTTLBlocks = int64(2_500_000)

	// MaxOpen caps simultaneously scheduled announcements, bounding both
	// storage and the cost of the Due/Expirable scans.
	MaxOpen = 200

	// MaxTextLen bounds one announcement. It is a BYTE length, not a rune
	// count, because its job is to bound storage; a multi-byte script
	// therefore gets fewer than 280 visible characters.
	MaxTextLen = 280

	// MaxPublishedKept is how many recent publications Render shows. The
	// permanent record is the emitted event; this is a bounded window so
	// realm storage cannot grow without limit.
	MaxPublishedKept = 50

	// MaxListed caps how many entries a single query returns.
	MaxListed = 50
)

// book holds the scheduled announcements. It is unexported and never
// returned: handing a *Book across a realm boundary would hand out the
// right to schedule, cancel and claim (duebook consumer contract 3).
var book = duebook.MustNew(MinDelayBlocks, MaxDelayBlocks, MaxOpen)

// publication is one published announcement, kept for rendering.
type publication struct {
	seq         int64
	deferralID  int64
	scheduler   address
	publisher   address
	text        string
	scheduledAt int64
	dueAt       int64
	publishedAt int64
}

var (
	published      = avl.NewTree() // padded seq -> *publication
	publishedTotal int64           // every publication ever, including evicted
	nextSeq        int64 = 1
)

// rejectStraySend aborts if an EOA attached coins to an entrypoint that
// has no use for them. This realm never holds value; without this guard a
// mistyped send would be silently absorbed by the realm bank.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// Schedule registers an announcement to be published no earlier than
// delayBlocks from the current height, and returns its deferral ID.
//
// ttlBlocks is how long after the due height the announcement stays
// publishable; 0 means it never expires. The caller becomes the owner and
// is the only account that may Cancel it.
func Schedule(cur realm, text string, delayBlocks, ttlBlocks int64) string {
	rejectStraySend(cur)

	if text == "" {
		panic("announcement text must not be empty")
	}
	if len(text) > MaxTextLen {
		panic("announcement text exceeds " + itoa(MaxTextLen) + " bytes")
	}
	if ttlBlocks < 0 || ttlBlocks > MaxTTLBlocks {
		panic("ttlBlocks out of range [0, " + itoa(MaxTTLBlocks) + "]")
	}

	owner := cur.Previous().Address()
	// The clock is the chain's, never an argument (consumer contract 1).
	now := runtime.ChainHeight()

	// duebook validates delayBlocks against the book's own bounds and
	// returns an error rather than panicking; a realm turns that into an
	// aborted transaction so nothing is half-applied.
	id, err := book.Schedule(owner.String(), text, now, delayBlocks, ttlBlocks)
	if err != nil {
		panic(err)
	}

	d, _ := book.Get(id)
	chain.Emit("Scheduled",
		"id", utoa(id),
		"scheduler", owner.String(),
		"dueAt", itoa(d.DueAt),
		"expiresAt", itoa(d.ExpiresAt),
	)
	return utoa(id)
}

// Publish publishes a scheduled announcement once it is due. It is
// deliberately permissionless: duebook's exactly-once Claim is the only
// thing preventing a second publication, which is precisely what this
// realm exists to demonstrate.
//
// Aborts if the announcement does not exist, is not due yet, has expired,
// or has already been consumed by a publication or a cancellation.
func Publish(cur realm, id int64) string {
	rejectStraySend(cur)

	did := mustID(id)
	now := runtime.ChainHeight()

	// CONSUME FIRST. Claim removes the deferral before returning, so by
	// the time the effect below runs, no second Claim of this ID can ever
	// succeed — in this transaction or any future one.
	d, err := book.Claim(did, now)
	if err != nil {
		panic(err)
	}

	// EFFECT SECOND, same transaction (consumer contract 5).
	publisher := cur.Previous().Address()
	seq := nextSeq
	nextSeq++
	publishedTotal++

	published.Set(seqKey(seq), &publication{
		seq:         seq,
		deferralID:  int64(d.ID),
		scheduler:   address(d.Owner),
		publisher:   publisher,
		text:        d.Payload,
		scheduledAt: d.CreatedAt,
		dueAt:       d.DueAt,
		publishedAt: now,
	})
	evictOldest()

	chain.Emit("Published",
		"id", utoa(d.ID),
		"seq", itoa(seq),
		"scheduler", d.Owner,
		"publisher", publisher.String(),
		"height", itoa(now),
	)
	return "published " + utoa(d.ID) + " at height " + itoa(now)
}

// Cancel withdraws a scheduled announcement before it is published. Only
// the account that scheduled it may cancel, and only while it is still
// open — a cancellation that arrives after publication aborts.
func Cancel(cur realm, id int64) string {
	rejectStraySend(cur)

	did := mustID(id)
	caller := cur.Previous().Address()

	// Ownership is checked by duebook against the address this realm
	// recorded at Schedule, never against a caller-supplied argument.
	d, err := book.Cancel(did, caller.String())
	if err != nil {
		panic(err)
	}

	chain.Emit("Cancelled", "id", utoa(d.ID), "scheduler", d.Owner)
	return "cancelled " + utoa(d.ID)
}

// Expire clears an announcement whose time-to-live has elapsed, freeing
// its slot against MaxOpen. It is permissionless because an expired
// announcement can never be published, so there is nothing left to
// protect and everything to gain from letting anyone tidy up.
func Expire(cur realm, id int64) string {
	rejectStraySend(cur)

	did := mustID(id)
	now := runtime.ChainHeight()

	d, err := book.Expire(did, now)
	if err != nil {
		panic(err)
	}

	chain.Emit("Expired", "id", utoa(d.ID), "scheduler", d.Owner, "height", itoa(now))
	return "expired " + utoa(d.ID)
}

// --- read-only views -------------------------------------------------------
// None of these authorize anything: only Publish's successful Claim does.

// Height returns the chain height this realm is reading as "now".
func Height() int64 { return runtime.ChainHeight() }

// OpenCount returns how many announcements are currently scheduled.
func OpenCount() int { return book.OpenCount() }

// PublishedTotal returns how many announcements have ever been published,
// including ones since evicted from the rendered window.
func PublishedTotal() int64 { return publishedTotal }

// NextID returns the deferral ID the next Schedule will allocate. It only
// ever increases; that is what makes a consumed ID permanently unusable.
func NextID() string { return utoa(book.NextID()) }

// Status describes a scheduled announcement: its window, and whether it is
// publishable right now. Returns "unknown" when the ID was never issued or
// has already been consumed — duebook keeps no tombstone, so those two
// cases are indistinguishable by design.
func Status(id int64) string {
	if id < 1 {
		return "unknown"
	}
	d, ok := book.Get(uint64(id))
	if !ok {
		return "unknown"
	}
	now := runtime.ChainHeight()
	state := "pending"
	switch {
	case d.IsExpired(now):
		state = "expired"
	case d.IsDue(now):
		state = "publishable"
	}
	out := state +
		" scheduler=" + d.Owner +
		" dueAt=" + itoa(d.DueAt) +
		" now=" + itoa(now)
	if d.ExpiresAt == 0 {
		return out + " expiresAt=never"
	}
	return out + " expiresAt=" + itoa(d.ExpiresAt)
}

// DueNow returns the IDs of announcements publishable at the current
// height, oldest first, capped at MaxListed.
func DueNow() string {
	ds := book.Due(runtime.ChainHeight(), MaxListed)
	if len(ds) == 0 {
		return ""
	}
	out := ""
	for i, d := range ds {
		if i > 0 {
			out += ","
		}
		out += utoa(d.ID)
	}
	return out
}

// ExpirableNow returns the IDs that Expire would accept at the current
// height, oldest first, capped at MaxListed.
func ExpirableNow() string {
	ds := book.Expirable(runtime.ChainHeight(), MaxListed)
	if len(ds) == 0 {
		return ""
	}
	out := ""
	for i, d := range ds {
		if i > 0 {
			out += ","
		}
		out += utoa(d.ID)
	}
	return out
}

// --- rendering -------------------------------------------------------------

// realmPath is this realm's gnoweb prefix, used to build view links.
const realmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/duebook_demo"

// Render serves three views, selected by path. Anyone may Schedule, so
// the default view must not be something a stranger can inflate: it
// shows only what is publishable right now, capped at MaxListed. The
// full scheduled table lives behind :open and is capped too, so no view
// is unbounded and none of them is the landing page by default.
//
//	(empty)  summary + publishable now + recent publications
//	open     every scheduled announcement, up to MaxListed rows
//	about    what this realm is and why it exists
func Render(path string) string {
	switch normalizePath(path) {
	case "open":
		return renderHeader() + renderOpen()
	case "about":
		return renderHeader() + renderAbout()
	default:
		return renderHeader() + renderDue() + renderPublished()
	}
}

func renderHeader() string {
	now := runtime.ChainHeight()
	s := "# Scheduled announcements\n\n"
	s += "Reference consumer for [duebook](/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/duebook).\n\n"
	s += "- height: " + itoa(now) + "\n"
	s += "- scheduled: " + itoa(int64(book.OpenCount())) + " / " + itoa(int64(MaxOpen)) + "\n"
	s += "- published (total): " + itoa(publishedTotal) + "\n"
	s += "- next id: " + utoa(book.NextID()) + "\n\n"
	s += "[summary](" + realmPath + ") · "
	s += "[all scheduled](" + realmPath + ":open) · "
	s += "[about](" + realmPath + ":about)\n\n"
	return s
}

// renderDue lists only what can be published at this height. book.Due
// applies the cap itself, so the slice is at most MaxListed long.
func renderDue() string {
	now := runtime.ChainHeight()
	ds := book.Due(now, MaxListed)

	s := "## Publishable now\n\n"
	if len(ds) == 0 {
		s += "_nothing is due at height " + itoa(now) + "._\n\n"
		return s
	}
	s += renderRows(ds, now)
	if book.OpenCount() > len(ds) {
		s += "\n" + itoa(int64(book.OpenCount()-len(ds))) +
			" more scheduled — see [all scheduled](" + realmPath + ":open).\n"
	}
	return s + "\n"
}

// renderOpen lists the whole book, stopping at MaxListed rows so this
// view has a fixed ceiling independent of MaxOpen.
func renderOpen() string {
	now := runtime.ChainHeight()

	s := "## Scheduled\n\n"
	if book.OpenCount() == 0 {
		return s + "_none_\n\n"
	}
	ds := []duebook.Deferral{}
	book.IterateOpen(func(d duebook.Deferral) bool {
		ds = append(ds, d)
		return len(ds) >= MaxListed
	})
	s += renderRows(ds, now)
	if book.OpenCount() > len(ds) {
		s += "\nShowing the first " + itoa(int64(len(ds))) + " of " +
			itoa(int64(book.OpenCount())) + ".\n"
	}
	return s + "\n"
}

func renderRows(ds []duebook.Deferral, now int64) string {
	s := "| id | scheduler | due at | expires | state |\n"
	s += "|---|---|---|---|---|\n"
	for _, d := range ds {
		state := "pending"
		switch {
		case d.IsExpired(now):
			state = "expired"
		case d.IsDue(now):
			state = "**publishable**"
		}
		exp := "never"
		if d.ExpiresAt != 0 {
			exp = itoa(d.ExpiresAt)
		}
		s += "| " + utoa(d.ID) +
			" | " + sanitize.InlineText(d.Owner) +
			" | " + itoa(d.DueAt) +
			" | " + exp +
			" | " + state + " |\n"
	}
	return s
}

// renderPublished shows the retained window, which evictOldest already
// holds at MaxPublishedKept entries.
func renderPublished() string {
	s := "## Published\n\n"
	if published.Size() == 0 {
		return s + "_none_\n\n"
	}
	s += "Most recent " + itoa(int64(MaxPublishedKept)) + " shown; the full record is in the emitted events.\n\n"
	published.Iterate("", "", func(_ string, v any) bool {
		p := v.(*publication)
		s += "**#" + itoa(p.seq) + "** (deferral " + itoa(p.deferralID) + ")"
		s += " scheduled at " + itoa(p.scheduledAt)
		s += ", due " + itoa(p.dueAt)
		s += ", published " + itoa(p.publishedAt) + "\n\n"
		// Blockquote, not InlineText: the slot IS a blockquote, and
		// the helper must be the one whose contract covers the slot.
		// InlineText happens to fold newlines today, which would
		// contain the payload by side effect — relying on that makes
		// safety version-bound to a helper that never promised it.
		// Blockquote emits its own "\n" ... "\n\n" envelope, so no
		// manual "> " prefix here (the helpers are not idempotent).
		s += sanitize.Blockquote(p.text)
		s += "by " + sanitize.InlineText(p.scheduler.String())
		s += " · published by " + sanitize.InlineText(p.publisher.String()) + "\n\n"
		return false
	})
	return s
}

func renderAbout() string {
	return "## About\n\n" +
		"Anyone may schedule an announcement to be published no earlier than " +
		"`delayBlocks` from now. Once due, **anyone** may publish it — " +
		"publication is deliberately permissionless, so the only thing " +
		"preventing a second publication is duebook's exactly-once `Claim`. " +
		"That is the experiment this realm exists to run.\n\n" +
		"The scheduler may cancel any time before publication. Once the " +
		"optional time-to-live elapses the announcement can never be " +
		"published, and anyone may clear it to free a slot.\n\n" +
		"This realm holds no coins and has no admin. Every entrypoint " +
		"rejects attached coins.\n\n" +
		"- min / max delay: " + itoa(MinDelayBlocks) + " / " + itoa(MaxDelayBlocks) + " blocks\n" +
		"- max time-to-live: " + itoa(MaxTTLBlocks) + " blocks\n" +
		"- max open at once: " + itoa(int64(MaxOpen)) + "\n" +
		"- max announcement length: " + itoa(int64(MaxTextLen)) + " bytes\n"
}

// normalizePath reduces a gnoweb render path to a bare view name, so
// "", "/", "open" and "/open/" all select the same view.
func normalizePath(path string) string {
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	for len(path) > 0 && path[len(path)-1] == '/' {
		path = path[:len(path)-1]
	}
	return path
}

// --- helpers ---------------------------------------------------------------

// mustID converts an exported int64 ID to duebook's uint64 form. IDs start
// at 1, so anything below that was never issued.
func mustID(id int64) uint64 {
	if id < 1 {
		panic("id must be positive")
	}
	return uint64(id)
}

// evictOldest trims the rendered window to MaxPublishedKept, dropping the
// lowest sequence numbers first. Evicted publications remain in the
// emitted events.
func evictOldest() {
	for published.Size() > MaxPublishedKept {
		oldest := ""
		published.Iterate("", "", func(key string, _ any) bool {
			oldest = key
			return true // first key in ascending order
		})
		if oldest == "" {
			return
		}
		published.Remove(oldest)
	}
}

// seqKey encodes a sequence number so avl's lexical order matches numeric
// order. Sequences are positive int64, at most 19 digits.
func seqKey(seq int64) string {
	s := strconv.FormatInt(seq, 10)
	const width = 19
	if len(s) >= width {
		return s
	}
	return "0000000000000000000"[:width-len(s)] + s
}

func itoa(n int64) string  { return strconv.FormatInt(n, 10) }
func utoa(n uint64) string { return strconv.FormatUint(n, 10) }
