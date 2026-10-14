// Package hlgov carries GovDAO's decisions to Solana (bridge/PLAN.md §5.3, §6.5, §13): a proposal made with one of
// the builders below, when it executes, dispatches a message through r/hlmailbox to the admin program — the
// decision's kind, its parameters and its sequence number (this realm's own counter, taken at execution) — and the
// admin program records it by that number and executes it after its clock. Anyone may re-dispatch an executed
// decision (the same number and parameters) until the admin program has recorded it. The builders check the
// parameters with the admin program's own rules, so a proposal that would fail on Solana is refused when it is made.
// Kind 4 is reserved and its builder refuses every call (§13); a cancel's body starts with an 8-byte salt drawn in
// the executing transaction, so two cancels of one list differ; kind 12 names a token's mint limits on the pausable
// ISM (the per-message maximum and the day cap, in base units), one of the 7-day group.
//
// Two decisions change this realm alone: `set decision recipient` (the program id decisions go to, a 7-day change,
// how a successor admin program ever receives one) and `sync sequence` (at once: the counter is raised — never
// lowered — to the number the admin program expects next, when a foreign decision has taken one, §6.5). The counter
// starts at a compiled number (launchSequence: 0 for a chain's first r/hlgov, the predecessor's last number for a
// successor), so no number the admin program recorded is ever reused. Before the Launch decision every builder
// but the cancel of a queued change here is refused. Who decides is the governor's (M1k): the compiled
// launchGovernor through Govern until it yields on r/hlmailbox, GovDAO's proposals after. Every launch value is
// compiled in below.
package hlgov

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlbubble"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlgnot"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlmailbox"
	"gno.land/r/gov/dao"
)

const (
	namespace = "gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/"
	pkgPath   = namespace + "hlgov" // must match gnomod.toml

	// The kinds (§13).
	KindCancel       = uint8(1)
	KindUnpause      = uint8(2)
	KindTokenISM     = uint8(3)
	KindReserved     = uint8(4) // reserved (§13): the client's state layout is fixed for the deployment's life; refused
	KindGuardians    = uint8(5)
	KindRouter      = uint8(6)
	KindProtocolFee = uint8(7)
	KindUpgrade     = uint8(8)
	KindSuccessor   = uint8(9)
	KindMintLimits  = uint8(12) // set mint limits (§13): a token's per-message maximum and day cap on the pausable ISM; the 7-day group

	maxCancel      = 16         // numbers one cancel names
	maxProtocolFee = 50_000_000 // lamports: the mailbox's max_protocol_fee, 0.05 SOL, fixed at its init (§5.5)
	// MaxDecisionBody bounds a decision's body (kind ‖ number ‖ params) at what Solana can ever deliver (the
	// assumptions audit's F18, M1g part 2): a legacy delivery of a decision carries at most 538 bytes of body — 529
	// of parameters, what 14 account keys and 127 bytes of fixed instruction data leave of the 1,232-byte packet —
	// and Hyperlane's mainnet mailbox dies on its own 32 KB heap past about 2,250 parameter bytes anyway (M2-NOTES
	// M2f), so a body no one can deliver would stick this realm's sequence with its number untaken, in a form no
	// program of ours cures. Every builder's body is far below (a cancel at most 163 bytes with its salt, kind 5 at
	// most 4 entries); the bound stands where this realm dispatches, checked when a proposal is made and in its
	// closure.
	MaxDecisionBody = 512
	syncReach      = uint64(1) << 32 // a sync sequence raises the counter by at most this (the realm's own bound, §13; kind 10 is reserved since v35)
	seatCount      = 6
	guardianSeats  = 4
	maxSeatChanges = 4 // kind 5: two guardian seats plus either watch slot

	// The launch values (§5.3, §6.5): the admin program (the first decision recipient), the pausable ISM (the only
	// id kind 3 may name), the light client (the pausable ISM's target, whose state layout is fixed for the
	// deployment's life — kind 4 is reserved — shown on the page for a member's check), and the four guardians' and
	// two watch keys' Solana pubkeys as the admin program's init data carries them. PLACEHOLDERS until the Solana
	// programs are deployed and the people have keys; bridge/local/e2e.sh swaps the program ids for its run's.
	launchRecipient   = "38885bd746ab9dc9b6175331a61842d0ad8e0c4c2532f72e286ef7dac82b0358" // the admin program 4ogRnw9iPGa4dY8qqCs1aBWxHQvKSzHh5ttz53sLFTM9
	launchPausableISM = "564eab462a321148f88d548996d0fd5e84c66ab630f0f4da63331592d7dce221" // the pausable ISM 6oudxto59ktYrpvqEVXTb5Tuo7vzBpkgnsPWoPXVF5Fv
	launchClient      = "1a572d156787a62750999f343e5af6f7394f91c11f75a2949e9aefd8914e07ad" // the light client 2mphYtLZ7HnCfrFhGH2c4Do9C9UoysevkmkDb8UkbAu2
	launchSolSeat1    = "05a1af200cfddc3b3ace76353505098855c9994913f7282f2e45ce6e473dcd6e" // Nz2u3N3RAMwq9pjw1Vv7ktN7nX4rNe4Uw5rdL9o9c3o
	launchSolSeat2    = "028b184c1fe43ac501409db4eb45a47bc2cd280226cca57345b802d27175e5b4" // AvqEe2hdx3HH87NU9CR5GSarCD1sR6PQ2H5AjwSnC4b
	launchSolSeat3    = "95b3b44e5adc9a0e849285e59cf6e7b0dab53e3a8772f680990f73a6111f494c" // B5NgM4oD1vYKTEGSe33RaSsHbyGzxKvoaycGqhjbyEV1
	launchSolSeat4    = "05ec99dd32dbee307eb064892f68581b9da9ee928df5a00d7f491f0f1b4fc3d2" // Q8HoML8efSufEhvYsSffmHAGJ6YnYb2QwyMVwQYt9Ds
	launchSolSeat5    = "195a00fb58ce0d7f762cc2b3d72017100724768fa2ae828c055d57530b34077a" // 2hxnxGiPf6cuuYXjThehyDnkXpUKjQai8fp14zkcgzjB
	launchSolSeat6    = "24551f378d8bbdc915fd4497aa9bf73a5eb5f99447755eb9f7c751aed3d558e2" // 3SpxeQf1JTfErvkpd3Kq33Q72H4yhLynKPVECdj9ckmf

	// launchSequence is the number of the last decision this realm's predecessor dispatched — 0 for a chain's
	// first r/hlgov. A successor r/hlgov for a new chain is deployed with its predecessor's last number here
	// (§5.3), so its counter starts where the admin program's stands and never restarts below a recorded number.
	// Written by init; the page shows it beside the counter.
	launchSequence = uint64(0)
)

// launchGovernor is the governor (M1k): the mailbox's, compiled here too so a member reads it in this realm's
// served source; init refuses a deploy with another. bridge/local/e2e.sh swaps it for gnodev's test1.
const launchGovernor = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")

var (
	destination = hlmailbox.LaunchOrigin()
	recipient   = mustKey(launchRecipient)
	former      [][32]byte               // every decision recipient a swap replaced (R29): retired admin programs, which kind 9 and a swap refuse for good
	client      = mustKey(launchClient)   // the light client: shown on the page; no kind names it (kind 4 is reserved)
	solSeats    [seatCount + 1][32]byte // Solana's seats as this realm last set them: a mirror kind 5 warns against, shown on the page

	last uint64   // the number of the last decision dispatched; the next is last + 1
	sent avl.Tree // seqKey(number) → *decision

	ledger decisions.Ledger
)

// decision is one dispatched decision: its body (kind ‖ number ‖ params) and its dispatches; a kind 6 for a route
// of this chain also keeps the route it enrolled and the height it noted with the mailbox (R37: a cancel of it
// clears that note while it is the latest).
type decision struct {
	kind   uint8
	body   []byte
	at     int64  // first dispatched
	id     string // the latest message id
	count  int    // dispatches so far
	text   string
	route  string // a kind 6 for this chain's domain: the route realm it enrolled; "" otherwise
	height int64  // … and the block height NoteEnrolled recorded for it
}

type (
	recipientParams struct{ to [32]byte }
	sequenceParams  struct{ n uint64 }
	cancelParams    struct{ id int64 }
	kindParams      struct {
		kind   uint8
		params []byte
		seats  []int
		keys   [][32]byte
	}
)

func init() {
	// a deploy whose compiled governor is not the mailbox's is refused (M1k): the bridge's realms are governed by
	// one key until it yields, or by GovDAO from the first block, never a mix
	if launchGovernor != hlmailbox.Governor() {
		panic("hlgov: the compiled governor " + string(launchGovernor) + " is not the mailbox's " + string(hlmailbox.Governor()))
	}
	solSeats[1], solSeats[2], solSeats[3] = mustKey(launchSolSeat1), mustKey(launchSolSeat2), mustKey(launchSolSeat3)
	solSeats[4], solSeats[5], solSeats[6] = mustKey(launchSolSeat4), mustKey(launchSolSeat5), mustKey(launchSolSeat6)
	last = launchSequence
}

func mustKey(s string) [32]byte {
	k, err := hl.ParseKey32(s)
	if err != nil {
		panic(err.Error())
	}
	return k
}

func now() int64 { return time.Now().Unix() }

func itoa(n int64) string   { return strconv.FormatInt(n, 10) }
func u64s(n uint64) string  { return strconv.FormatUint(n, 10) }
func hx(b []byte) string    { return hex.EncodeToString(b) }
func seqKey(n uint64) string { return strings.Repeat("0", 20-len(u64s(n))) + u64s(n) }

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("hlgov: that realm value is not live; pass your own cur")
	}
	return cur.Previous().Address()
}

func mustBeLive() {
	if !hlmailbox.Live() {
		panic("hlgov: not launched: before the Launch decision only the cancel of a queued change is proposed")
	}
}

// Request is what a builder returns (M1k): the proposal GovDAO's proxy executes after the yield (Proposal), and
// the same decision the governor runs directly before it (Govern); see hlgnot's.
type Request struct {
	proposal dao.ProposalRequest
	text     string
	decide   func(cur realm) error
}

// Proposal is the request as a GovDAO proposal: `dao.MustCreateProposal(cross(cur), req.Proposal())`.
func (r Request) Proposal() dao.ProposalRequest { return r.proposal }

// Description is the proposal's: the parameters as the builder wrote them.
func (r Request) Description() string { return r.text }

// who names a previous realm in a refusal: its pkgpath, or a user's address.
func who(path string, a address) string {
	if path != "" {
		return path
	}
	return string(a)
}

// mustBeGovernor is a decision's identity check (M1k), read from the closure's own live cur: the governor's own
// call until it yields on r/hlmailbox, gno.land/r/gov/dao's proxy exactly after (or from the first block, when no
// governor was compiled); see hlgnot's.
func mustBeGovernor(cur realm) {
	prev := cur.Previous()
	if decisions.DAOGoverns(launchGovernor, hlmailbox.Yielded()) {
		if p := prev.PkgPath(); p != decisions.DAOPath {
			panic("hlgov: only " + decisions.DAOPath + " executes a decision, not " + who(prev.PkgPath(), prev.Address()))
		}
		return
	}
	if !prev.IsUser() || prev.Address() != launchGovernor {
		panic("hlgov: until the governor yields, " + string(launchGovernor) + " alone decides, by Govern from its own key: not " + who(prev.PkgPath(), prev.Address()) + " (a GovDAO proposal is refused until the yield)")
	}
}

// Govern is the governor's way in before the yield (M1k): the same closure GovDAO's proxy runs after it, called
// non-crossing in this frame so it reads the governor from cur.Previous() — and dispatches through the mailbox
// under this realm's own authority, as the proxy's execution does; refused for anyone else and for everyone once
// the governor yielded on r/hlmailbox (or when none was compiled); see hlgnot's.
func Govern(cur realm, r Request) {
	if !cur.IsCurrent() {
		panic("hlgov: that realm value is not live; pass your own cur")
	}
	if r.decide == nil {
		panic("hlgov: not a builder's request")
	}
	if yielded := hlmailbox.Yielded(); decisions.DAOGoverns(launchGovernor, yielded) {
		if launchGovernor == "" {
			panic("hlgov: no governor was compiled, " + decisions.DAOPath + " governs from the first block: a decision is a GovDAO proposal, never Govern")
		}
		panic("hlgov: the governor yielded at height " + itoa(yielded) + ", " + decisions.DAOPath + " governs since: a decision is a GovDAO proposal, never Govern")
	}
	mustBeGovernor(cur)
	if err := r.decide(cur); err != nil {
		panic("hlgov: " + err.Error())
	}
}

// ------------------------------------------------------------- reading --

// Address is this realm's address: the sender the admin program accepts.
func Address() address { return chain.PackageAddress(pkgPath) }

// Recipient is the program decisions are addressed to, in hex.
func Recipient() string { return hx(recipient[:]) }

// Former lists every decision recipient a swap replaced, in hex, oldest first (R29): retired admin programs.
func Former() []string {
	out := make([]string, len(former))
	for i, k := range former {
		out[i] = hx(k[:])
	}
	return out
}

func isFormer(k [32]byte) bool {
	for _, f := range former {
		if f == k {
			return true
		}
	}
	return false
}

// mustNotBeFormer refuses a retired admin program as a kind 9's successor or as the decision recipient (R29): a
// program whose authorities went to a successor answers Retired to every decision, and a kind 9 naming it dies on
// its successor_init (NotInherited), so the decision would pend until a cancel — a wasted vote and a standing line
// on hlwatch. Checked when a proposal is made, in its closure, and when a queued swap would apply.
func mustNotBeFormer(k [32]byte, what string) {
	if isFormer(k) {
		panic("hlgov: never a former " + what + " (" + hx(k[:]) + "): it is retired, every authority handed to a successor by kind 9 — a kind 9 to it would die on its successor_init (NotInherited) and a swap to it would send every decision to a program that answers Retired")
	}
}

// Destination is the Solana domain decisions go to.
func Destination() uint32 { return destination }

// Last is the number of the last decision dispatched; Next the number the next one takes; Start the compiled
// number the counter began at (the predecessor's last number; 0 for a chain's first r/hlgov).
func Last() uint64  { return last }
func Next() uint64  { return last + 1 }
func Start() uint64 { return launchSequence }

// SolSeat is the Solana pubkey this realm last set for a seat (1–4 guardians, 5–6 watch keys), in hex.
func SolSeat(n int) string {
	if n < 1 || n > seatCount {
		return ""
	}
	return hx(solSeats[n][:])
}

// Body is a dispatched decision's body in hex, by number ("" if none).
func Body(n uint64) string {
	v := sent.Get(seqKey(n))
	if v == nil {
		return ""
	}
	return hx(v.(*decision).body)
}

// -------------------------------------------------------------- encoding --

func be32(n uint32) []byte { return binary.BigEndian.AppendUint32(nil, n) }
func be64(n uint64) []byte { return binary.BigEndian.AppendUint64(nil, n) }

// body is kind u8 ‖ seq u64 BE ‖ params (§13).
func body(kind uint8, n uint64, params []byte) []byte {
	b := make([]byte, 0, 9+len(params))
	b = append(b, kind)
	b = append(b, be64(n)...)
	return append(b, params...)
}

// mustFit refuses a body above MaxDecisionBody: the one check every dispatch makes, so no builder can author a
// decision the mailbox cannot deliver.
func mustFit(raw []byte) {
	if len(raw) > MaxDecisionBody {
		panic("hlgov: the decision body is " + strconv.Itoa(len(raw)) + " bytes, above the " + strconv.Itoa(MaxDecisionBody) + " the mailbox delivers (MaxDecisionBody): it would stick the sequence with its number untaken")
	}
}

// dispatch sends a decision with the next number and records it; a body above MaxDecisionBody is refused first.
func dispatch(cur realm, kind uint8, params []byte, text string, t int64) uint64 {
	n := last + 1
	raw := body(kind, n, params)
	mustFit(raw)
	id := hlmailbox.Dispatch(cross(cur), destination, recipient, raw)
	last = n
	sent.Set(seqKey(n), &decision{kind: kind, body: raw, at: t, id: hx(id[:]), count: 1, text: text})
	chain.Emit("DecisionSent", "number", u64s(n), "kind", strconv.Itoa(int(kind)), "id", hx(id[:]))
	return n
}

// Redispatch sends an executed decision again — the same number and parameters, a new message — by anyone, until
// the admin program has recorded it (a copy it has recorded is accepted and ignored there).
func Redispatch(cur realm, n uint64) {
	caller(cur)
	v := sent.Get(seqKey(n))
	if v == nil {
		panic("hlgov: no decision " + u64s(n))
	}
	d := v.(*decision)
	id := hlmailbox.Dispatch(cross(cur), destination, recipient, d.body)
	d.id = hx(id[:])
	d.count++
	chain.Emit("DecisionSent", "number", u64s(n), "kind", strconv.Itoa(int(d.kind)), "id", hx(id[:]))
}

// ------------------------------------------------------------- builders --

func propose(cur realm, kind, text string, apply func(cur realm, made, t int64)) Request {
	if !cur.IsCurrent() {
		panic("hlgov: that realm value is not live; pass your own cur")
	}
	made := now()
	cb := func(cur realm) error {
		mustBeGovernor(cur)
		t := now()
		if err := decisions.Expired(made, t); err != nil {
			return err
		}
		apply(cur, made, t)
		return nil
	}
	return Request{proposal: dao.NewProposalRequest("hlgov: "+kind, text, dao.NewSimpleExecutor(0, cur, cb, text)), text: text, decide: cb}
}

// proposeKind is a Solana decision's builder: at execution it dispatches the message and records the decision as
// applied; the parameters were checked at creation and are checked again then, the body's size with them.
func proposeKind(cur realm, kind uint8, name, text string, params []byte, check func()) Request {
	mustBeLive()
	mustFit(body(kind, 0, params))
	check()
	return propose(cur, name, text, func(cur realm, made, t int64) {
		mustBeLive()
		check()
		n := dispatch(cur, kind, params, text, t)
		d := ledger.Record(name, text, kindParams{kind: kind, params: params}, made, t, t)
		ledger.Apply(d, t, "dispatched as decision "+u64s(n))
	})
}

func parseNumber(p string) uint64 {
	n, err := strconv.ParseUint(strings.TrimSpace(p), 10, 64)
	if err != nil || n == 0 {
		panic("hlgov: not a decision number: " + p)
	}
	return n
}

// salt is the 8 bytes a cancel body starts with (§13: random, ignored by the program,
// so no body is predictable and two cancels of one list differ). gno.land gives a realm no block
// hash, so it is sha256 over what the block and the decision give — the chain id, the height, the block time, the
// mailbox's nonce, the decision number and the ledger's next id — drawn in the executing transaction; the decision
// number alone makes two cancels of one list differ, the rest make it as unpredictable as the block it lands in.
func salt(t int64) []byte {
	b := []byte(runtime.ChainID())
	b = append(b, be64(uint64(runtime.ChainHeight()))...)
	b = append(b, be64(uint64(t))...)
	b = append(b, be32(hlmailbox.Count())...)
	b = append(b, be64(last+1)...)
	b = append(b, be64(uint64(ledger.Last()+1))...)
	h := sha256.Sum256(b)
	return h[:8]
}

// NewCancelRequest is kind 1: cancel pending decisions of the mailbox channel on Solana (channel 0, the only one
// this realm writes), by a list of numbers (comma separated, at most 16: form 0) or by a range "from-to",
// inclusive (form 1); each number one this realm dispatched. It executes at once there. The body is
// `salt u64 ‖ form u8 ‖ …` (§13), the salt drawn when the proposal executes, so the description names the numbers
// and the ledger's note and the decision's page carry the salt.
func NewCancelRequest(cur realm, numbers string) Request {
	mustBeLive()
	var params []byte
	var top uint64
	if i := strings.Index(numbers, "-"); i >= 0 {
		from, to := parseNumber(numbers[:i]), parseNumber(numbers[i+1:])
		if to < from {
			panic("hlgov: the range runs from the lower number to the higher")
		}
		params = append([]byte{1, 0}, be64(from)...)
		params = append(params, be64(to)...)
		top = to
	} else {
		var ns []uint64
		for _, p := range strings.Split(numbers, ",") {
			if strings.TrimSpace(p) == "" {
				continue
			}
			n := parseNumber(p)
			for _, x := range ns {
				if x == n {
					panic("hlgov: number " + strings.TrimSpace(p) + " named twice")
				}
			}
			ns = append(ns, n)
			if n > top {
				top = n
			}
		}
		if len(ns) == 0 || len(ns) > maxCancel {
			panic("hlgov: a cancel names 1 to " + strconv.Itoa(maxCancel) + " numbers, or a range")
		}
		params = []byte{0, byte(len(ns))}
		for _, n := range ns {
			params = append(params, 0)
			params = append(params, be64(n)...)
		}
	}
	text := "cancel decisions " + numbers
	mustFit(body(KindCancel, 0, append(make([]byte, 8), params...))) // with the salt's 8 bytes; dispatch checks it again
	check := func() {
		if top > last {
			panic("hlgov: decision " + u64s(top) + " was never dispatched")
		}
	}
	check()
	return propose(cur, "cancel", text, func(cur realm, made, t int64) {
		mustBeLive()
		check()
		p := append(salt(t), params...)
		n := dispatch(cur, KindCancel, p, text, t)
		note := "dispatched as decision " + u64s(n) + ", salt " + hx(p[:8])
		// a cancelled kind 6 for a route of this chain clears the enrolment note it left, while that note is the
		// latest (R37, AS2): the route's refund clock restarts with a re-proposal, instead of opening on a kind 6
		// Solana never executed
		eachCancelled(numbers, func(num uint64, d *decision) {
			if d.kind != KindRouter || d.route == "" {
				return
			}
			if h, _ := hlmailbox.Enrolled(d.route); h != d.height {
				return
			}
			hlmailbox.ClearEnrolled(cross(cur), d.route)
			note += "; the enrolment note of " + d.route + " cleared (kind 6 #" + u64s(num) + " cancelled): its refund clock restarts with a re-proposal"
		})
		d := ledger.Record("cancel", text, kindParams{kind: KindCancel, params: p}, made, t, t)
		ledger.Apply(d, t, note)
	})
}

// eachCancelled walks the decisions a cancel's numbers name — the list, or every dispatched number of the range —
// in number order.
func eachCancelled(numbers string, fn func(n uint64, d *decision)) {
	if i := strings.Index(numbers, "-"); i >= 0 {
		from, to := parseNumber(numbers[:i]), parseNumber(numbers[i+1:])
		sent.Iterate(seqKey(from), seqKey(to+1), func(k string, v any) bool {
			n, _ := strconv.ParseUint(strings.TrimLeft(k, "0"), 10, 64)
			fn(n, v.(*decision))
			return false
		})
		return
	}
	for _, p := range strings.Split(numbers, ",") {
		if strings.TrimSpace(p) == "" {
			continue
		}
		n := parseNumber(p)
		if v := sent.Get(seqKey(n)); v != nil {
			fn(n, v.(*decision))
		}
	}
}

// NewUnpauseRequest is kind 2: clear the flags set before its delivery on the pausable ISM (object 0) or the admin
// program (object 1), 24 hours after it arrives, unless two guardians' flags hold.
func NewUnpauseRequest(cur realm, object uint8) Request {
	if object > 1 {
		panic("hlgov: the object is 0 (the pausable ISM) or 1 (the admin program)")
	}
	name := "the pausable ISM"
	if object == 1 {
		name = "the admin program"
	}
	return proposeKind(cur, KindUnpause, "unpause", "unpause "+name, []byte{object}, func() {})
}

func parseToken(token uint8) string {
	switch token {
	case 0:
		return "GNOT"
	case 1:
		return "BUBBLE"
	}
	panic("hlgov: the token is 0 (GNOT) or 1 (BUBBLE)")
}

// NewSetTokenISMRequest is kind 3: point a token (0 GNOT, 1 BUBBLE) at the pausable ISM, or at none (all zeros).
func NewSetTokenISMRequest(cur realm, token uint8, ism string) Request {
	name := parseToken(token)
	k := mustKey(ism)
	if k != mustKey(launchPausableISM) && k != ([32]byte{}) {
		panic("hlgov: the ISM must be the pausable ISM " + launchPausableISM + " or all zeros")
	}
	params := append([]byte{token}, k[:]...)
	return proposeKind(cur, KindTokenISM, "set token ISM", "set "+name+"'s ISM to "+hx(k[:]), params, func() {})
}

// NewSetClientLayoutRequest is kind 4, which §13 reserves (v27, AM7): the client's state layout the pausable ISM
// and the immutable admin program read is fixed for the deployment's life (version 1), a client upgrade keeps it,
// and a new layout is a successor admin program and pausable ISM by kind 9. The builder refuses every call, so no
// kind-4 message ever leaves here; the admin program refuses one at execution too.
func NewSetClientLayoutRequest(cur realm, target string, version uint8) Request {
	panic("hlgov: kind 4 is reserved: the client's state layout is fixed for the deployment's life (version 1); a new layout is a successor by kind 9")
}

// parseSeatChanges reads "seat:pubkey" pairs (comma separated; the pubkey in base58 or hex): seats 1–6, two
// guardian seats at most, four entries at most, no seat or key twice.
func parseSeatChanges(changes string) ([]int, [][32]byte) {
	var ns []int
	var ks [][32]byte
	g := 0
	for _, p := range strings.Split(changes, ",") {
		i := strings.Index(p, ":")
		if i < 0 {
			panic("hlgov: a change is seat:pubkey, not " + p)
		}
		n, err := strconv.Atoi(strings.TrimSpace(p[:i]))
		if err != nil || n < 1 || n > seatCount {
			panic("hlgov: the seat must be 1 to 6, not " + p[:i])
		}
		for _, x := range ns {
			if x == n {
				panic("hlgov: seat " + strconv.Itoa(n) + " named twice")
			}
		}
		k := mustKey(p[i+1:])
		if k == ([32]byte{}) {
			panic("hlgov: a pubkey of zeros")
		}
		for _, x := range ks {
			if x == k {
				panic("hlgov: a pubkey named twice")
			}
		}
		if n <= guardianSeats {
			g++
		}
		ns = append(ns, n)
		ks = append(ks, k)
	}
	if len(ns) == 0 || len(ns) > maxSeatChanges {
		panic("hlgov: 1 to " + strconv.Itoa(maxSeatChanges) + " seats per decision")
	}
	if g > 2 {
		panic("hlgov: two guardian seats at most per decision")
	}
	return ns, ks
}

// seatWarnings names the keys that hold a seat as this realm last set it. The real seats are Solana's, and the
// admin program refuses a seat's current key itself (§6.5), spending the decision: a true no-op. The mirror here
// can sit ahead of the truth (a kind 5 the admin program spent) or behind it (a kind 5 of another decision moved a seat),
// so it is no ground to refuse a proposal — the builder warns in the description and the member reads
// `hlwatch`'s list of the seats as they stand.
func seatWarnings(ns []int, ks [][32]byte) string {
	var parts []string
	for i := range ns {
		for s := 1; s <= seatCount; s++ {
			if solSeats[s] == ks[i] {
				parts = append(parts, hx(ks[i][:])+" holds seat "+strconv.Itoa(s)+" as last set here")
			}
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return " (warning: " + strings.Join(parts, "; ") + " — the admin program spends a decision naming a seat's current key, so check the seats as they stand on Solana before voting)"
}

// NewSetGuardiansRequest is kind 5: replace guardian seats (1–4, two at most) and watch slots (5–6) on Solana,
// four entries at most. A key that holds a seat as this realm last set it is warned about in the description,
// not refused: the admin program's own check spends a decision naming a seat's current key, and this realm's
// mirror of the seats can drift from the truth. It lands 7 days after delivery through any flag or hold.
func NewSetGuardiansRequest(cur realm, changes string) Request {
	mustBeLive()
	ns, ks := parseSeatChanges(changes)
	params := []byte{byte(len(ns))}
	parts := make([]string, len(ns))
	for i, n := range ns {
		params = append(params, byte(n))
		params = append(params, ks[i][:]...)
		parts[i] = "seat " + strconv.Itoa(n) + " to " + hx(ks[i][:])
	}
	text := "set guardians and watch keys: " + strings.Join(parts, ", ") + seatWarnings(ns, ks)
	return propose(cur, "set guardians", text, func(cur realm, made, t int64) {
		mustBeLive()
		n := dispatch(cur, KindGuardians, params, text, t)
		for i, s := range ns {
			solSeats[s] = ks[i]
		}
		d := ledger.Record("set guardians", text, kindParams{kind: KindGuardians, params: params, seats: ns, keys: ks}, made, t, t)
		ledger.Apply(d, t, "dispatched as decision "+u64s(n))
	})
}

// NewEnrollRouterRequest is kind 6: enroll a token's remote router for a domain. For gno.land's own domain the
// router must be a route realm registered with hlmailbox — the launch routes, and the successors their migrations
// named — as 32 bytes: the synthetic program takes every Dispatch from the router it enrolls as a mint order, and
// hlmailbox's Dispatch is open to any realm, so any other address would mint synthetic that no lock backs; the
// token's own route (R36), unmigrated, and — a successor — one that pulled page 0 (R35). The rules are checked
// when the proposal is made and again when it executes. The closure then notes with the mailbox the route it
// enrolled and the height (hlmailbox.NoteEnrolled, AR1): that route's refund builder waits 14 days after the note
// (R37: a week for the delivery, a week for Solana's clock), since a refunded send stays deliverable on Solana
// until the predecessor's router is replaced; a cancel of the kind 6 clears the note (NewCancelRequest).
func NewEnrollRouterRequest(cur realm, token uint8, domain uint32, router string) Request {
	mustBeLive()
	name := parseToken(token)
	k := mustKey(router)
	if k == ([32]byte{}) || domain == 0 {
		panic("hlgov: the router and the domain must be set")
	}
	local := domain == hlmailbox.LocalDomain()
	check := func() string {
		if !local {
			return ""
		}
		path := routePathOf(k)
		if path == "" {
			panic("hlgov: for this chain's domain the router must be a route realm registered with hlmailbox, not " + hx(k[:]))
		}
		// the token's own route, and a live one (R36): the other token's route — or its successor — as this
		// token's router strands this token's burns behind per-id votes until a corrective kind 6 lands, refuses
		// its sends on Solana meanwhile, and writes the enrolment note on the other route, opening its refunds
		// while the other token's router still delivers (AR1's double mint again); a migrated route's successor
		// is the token's router, never the route itself
		if sym := hlmailbox.RouteSymbol(path); sym == "" {
			panic("hlgov: " + path + " is registered for no token (it never announced the route it succeeds): a kind 6 names the token's own route")
		} else if sym != name {
			panic("hlgov: " + path + " is the " + sym + " route's, not " + name + "'s: a kind 6 names the token's own route")
		}
		if s := hlmailbox.Successor(path); s != "" {
			panic("hlgov: " + path + " migrated to " + s + ": never a migrated route, since its successor is the token's router")
		}
		// a successor that pulled nothing is never enrolled (R35): before page 0 its migration may still be
		// re-pointed (AR2) and the route dropped — a realm in nobody's chain that Solana would then name the
		// router for the deployment's life, every burn's recipient, flaggable by nobody
		if pred := hlmailbox.Predecessor(path); pred != "" && !hlmailbox.Pulled(path) {
			panic("hlgov: " + path + " succeeds " + pred + " and has pulled nothing yet (page 0 is not in): a kind 6 enrolling it waits for its first page, since a migrate that pulled nothing may be re-pointed and Solana must never name a dropped route")
		}
		return path
	}
	params := append(append([]byte{token}, be32(domain)...), k[:]...)
	text := "enroll " + name + "'s router for domain " + strconv.FormatUint(uint64(domain), 10) + ": " + hx(k[:])
	mustFit(body(KindRouter, 0, params))
	check()
	return propose(cur, "enroll router", text, func(cur realm, made, t int64) {
		mustBeLive()
		path := check()
		n := dispatch(cur, KindRouter, params, text, t)
		note := "dispatched as decision " + u64s(n)
		if path != "" {
			h := runtime.ChainHeight()
			hlmailbox.NoteEnrolled(cross(cur), path, h)
			sd := sent.Get(seqKey(n)).(*decision)
			sd.route, sd.height = path, h
			note += "; " + path + " noted enrolled on Solana at height " + itoa(h)
		}
		d := ledger.Record("enroll router", text, kindParams{kind: KindRouter, params: params}, made, t, t)
		ledger.Apply(d, t, note)
	})
}

// routePathOf is the pkgpath of the route realm hlmailbox registers whose address, as 32 bytes, is k; "" if none.
func routePathOf(k [32]byte) string {
	for _, path := range hlmailbox.Routes() {
		if b, err := hl.AddressToBytes32(chain.PackageAddress(path)); err == nil && b == k {
			return path
		}
	}
	return ""
}

// NewSetProtocolFeeRequest is kind 7: the mailbox's protocol fee (lamports, at most its 0.05 SOL maximum) and its
// beneficiary (the treasurer's Solana key).
func NewSetProtocolFeeRequest(cur realm, lamports uint64, beneficiary string) Request {
	if lamports > maxProtocolFee {
		panic("hlgov: the fee is at most " + u64s(maxProtocolFee) + " lamports, the mailbox's maximum")
	}
	k := mustKey(beneficiary)
	if k == ([32]byte{}) {
		panic("hlgov: a beneficiary of zeros")
	}
	params := append(be64(lamports), k[:]...)
	return proposeKind(cur, KindProtocolFee, "set protocol fee", "set the protocol fee to "+u64s(lamports)+" lamports for "+hx(k[:]), params, func() {})
}

// NewUpgradeRequest is kind 8: upgrade a program from a staged buffer whose ELF hashes to elfHash (sha256, hex) —
// never the admin program's own id (§13: its upgrade authority is burned, so the decision could only be spent; a
// new admin program is a successor by kind 9), checked when the proposal is made and when it executes.
func NewUpgradeRequest(cur realm, program, buffer, elfHash string) Request {
	p, b, h := mustKey(program), mustKey(buffer), mustKey(elfHash)
	if p == ([32]byte{}) || b == ([32]byte{}) || h == ([32]byte{}) || p == b {
		panic("hlgov: the program, the buffer and the hash must be set and distinct")
	}
	check := func() {
		if p == recipient {
			panic("hlgov: never the admin program's own id (" + hx(p[:]) + "): it is immutable, a new admin program is a successor by kind 9")
		}
	}
	params := append(append(append([]byte{}, p[:]...), b[:]...), h[:]...)
	return proposeKind(cur, KindUpgrade, "upgrade", "upgrade "+hx(p[:])+" from buffer "+hx(b[:])+" with ELF sha256 "+hx(h[:]), params, check)
}

// NewTransferToSuccessorRequest is kind 9: hand every authority to an immutable successor admin program — never
// the admin program itself, the decision recipient this realm knows, checked when the proposal is made and again
// when it executes (a recipient swap landing in between would otherwise turn a pre-armed transfer into one the
// admin program only spends: it re-points every authority to itself and dies on its own SuccessorInit, the
// programs lane's S-15), as kind 8 refuses its self-upgrade; and never a former recipient (R29), a retired program
// whose successor_init answers NotInherited. The admin program refuses a successor whose programdata shows an
// upgrade authority; the builder cannot read Solana, so a member checks that by RPC before proposing.
func NewTransferToSuccessorRequest(cur realm, program string) Request {
	p := mustKey(program)
	if p == ([32]byte{}) {
		panic("hlgov: the successor must be set")
	}
	check := func() {
		if p == recipient {
			panic("hlgov: never the admin program itself (" + hx(p[:]) + "), not the current admin program as its own successor: the admin program would only spend the decision")
		}
		mustNotBeFormer(p, "admin program")
	}
	return proposeKind(cur, KindSuccessor, "transfer to successor", "transfer every authority to "+hx(p[:]), p[:], check)
}

// routeMaximum is a token's per-message maximum on its gno.land route now (base units): what a send may carry out.
func routeMaximum(token uint8) uint64 {
	if token == 0 {
		return uint64(hlgnot.Maximum())
	}
	return uint64(hlbubble.Maximum())
}

// NewSetMintLimitsRequest is kind 12: a token's (0 GNOT, 1 BUBBLE) per-message maximum and rolling day cap on the
// pausable ISM, in base units (§13: token u8 ‖ maximum u64 ‖ day cap u64; compiled there at launch as 25,000 a
// message and 100,000 a day of each token). A maximum of 0 (every mint refused) and a day cap below the maximum (a
// message at the maximum could never pass) are refused when the proposal is made: the admin program and the
// pausable ISM take any values, so the nonsense is caught here, as every builder catches it early. The maximum is
// never below the token's route's per-message maximum on gno.land (R15), checked when the proposal is made and
// when it executes: a send between the two would leave gno.land and be refused at delivery for good, stranded
// until a refund by id — so a raise is the Solana limit first (this), the route's maximum after, and a lowering
// the other way round. It lands 7 days after delivery.
func NewSetMintLimitsRequest(cur realm, token uint8, maximum, dayCap uint64) Request {
	name := parseToken(token)
	if maximum == 0 {
		panic("hlgov: the per-message maximum is at least 1")
	}
	if dayCap < maximum {
		panic("hlgov: the day cap is at least the per-message maximum")
	}
	check := func() {
		if rm := routeMaximum(token); maximum < rm {
			panic("hlgov: a per-message maximum of " + u64s(maximum) + " is below the " + name + " route's maximum of " + u64s(rm) + " (base units): a send between the two would strand on Solana — lower the route's maximum first, then this")
		}
	}
	params := append([]byte{token}, be64(maximum)...)
	params = append(params, be64(dayCap)...)
	text := "set " + name + "'s mint limits: " + u64s(maximum) + " a message, " + u64s(dayCap) + " a day (base units)"
	return proposeKind(cur, KindMintLimits, "set mint limits", text, params, check)
}

// mustRaise refuses a sync sequence that would not raise the counter (§5.3: it never lowers it): n is the number
// the next decision takes, so the counter becomes n-1, which must be above the counter now — and by at most 2^32,
// the realm's own bound (§13, R18; kind 10 is reserved since v35 and moves nothing on Solana), so a mistyped
// number can neither wrap the counter onto numbers the admin program recorded nor put every decision beyond the
// next number it expects.
func mustRaise(n uint64) {
	if n == last+1 {
		panic("hlgov: the next number is " + u64s(n) + " already")
	}
	if n <= last {
		panic("hlgov: sync sequence only ever raises the counter: it stands at " + u64s(last) + " (the next number is " + u64s(last+1) + ") and " + u64s(n) + " is not above it")
	}
	if n > last+1+syncReach {
		panic("hlgov: sync sequence reaches at most 2^32 above the next number (the realm's own bound): the next number is " + u64s(last+1) + " and " + u64s(n) + " is beyond " + u64s(last+1+syncReach))
	}
}

// NewSyncSequenceRequest raises this realm's counter so that the next decision takes number n — the number the
// admin program expects next after a foreign decision took one — at once; nothing moves on Solana. It only ever
// raises: a number at or below the next one is refused when the proposal is made and again when it executes (the
// counter may have moved in between), so a number the admin program recorded is never reused.
func NewSyncSequenceRequest(cur realm, n uint64) Request {
	mustBeLive()
	if n == 0 {
		panic("hlgov: the next number is at least 1")
	}
	mustRaise(n)
	text := "sync sequence: the next decision takes number " + u64s(n) + " (it was " + u64s(last+1) + ")"
	return propose(cur, "sync sequence", text, func(cur realm, made, t int64) {
		mustBeLive()
		mustRaise(n)
		last = n - 1
		d := ledger.Record("sync sequence", text, sequenceParams{n}, made, t, t)
		ledger.Apply(d, t, "at once")
		chain.Emit("SequenceSynced", "next", u64s(n))
	})
}

// NewSetDecisionRecipientRequest changes the program decisions are addressed to, 7 days after the proposal
// executes: how a successor admin program receives them. Never the current recipient, and never a former one
// (R29: a retired program answers Retired to every decision) — checked when the proposal is made, in its closure
// and when the queued change would apply.
func NewSetDecisionRecipientRequest(cur realm, program string) Request {
	mustBeLive()
	p := mustKey(program)
	if p == ([32]byte{}) {
		panic("hlgov: the recipient must be set")
	}
	check := func() {
		if p == recipient {
			panic("hlgov: the recipient must differ from the current one (" + hx(p[:]) + ")")
		}
		mustNotBeFormer(p, "decision recipient")
	}
	check()
	text := "set decision recipient to " + hx(p[:]) + " (now " + hx(recipient[:]) + ")"
	return propose(cur, "set decision recipient", text, func(cur realm, made, t int64) {
		mustBeLive()
		check()
		d := ledger.Record("set decision recipient", text, recipientParams{p}, made, t, t+decisions.Delay)
		d.Note = "queued 7 days"
	})
}

// NewCancelQueuedRequest cancels a queued change of this realm (a recipient swap), at once; it is proposed before
// Launch too.
func NewCancelQueuedRequest(cur realm, id int64) Request {
	d := ledger.Get(id)
	if d == nil || !d.Pending() {
		panic("hlgov: decision " + itoa(id) + " is not pending")
	}
	text := "cancel queued change " + itoa(id) + " (" + d.Text + ")"
	return propose(cur, "cancel queued", text, func(cur realm, made, t int64) {
		if _, err := ledger.Cancel(id, t); err != nil {
			panic("hlgov: " + err.Error())
		}
		c := ledger.Record("cancel queued", text, cancelParams{id}, made, t, t)
		ledger.Apply(c, t, "at once: cancelled")
	})
}

// Execute applies a queued change (a recipient swap) whose 7 days have passed; anyone may call it. A swap decided
// while its target was nobody applies only while that holds (R29): one that finds its target the recipient already
// (a second swap to the same program) or a former recipient (replaced since) is refused and stays pending for
// GovDAO's cancel; the recipient it replaces joins the former ones.
func Execute(cur realm, id int64) {
	caller(cur)
	mustBeLive()
	t := now()
	d, err := ledger.Due(id, t)
	if err != nil {
		panic("hlgov: " + err.Error())
	}
	p, ok := d.Params.(recipientParams)
	if !ok {
		panic("hlgov: decision " + itoa(id) + " has nothing to apply")
	}
	if p.to == recipient {
		panic("hlgov: " + hx(p.to[:]) + " is the decision recipient already: cancel decision " + itoa(id))
	}
	mustNotBeFormer(p.to, "decision recipient")
	former = append(former, recipient)
	recipient = p.to
	ledger.Apply(d, t, "applied after the delay")
	chain.Emit("RecipientSet", "program", hx(recipient[:]))
}

// --------------------------------------------------------------- pages --

// Render: "" the page; "json"; "decisions" and "decisions.json" the ledger; "decision/<n>" one dispatched decision.
func Render(path string) string {
	switch {
	case path == "":
		var b strings.Builder
		b.WriteString("# GovDAO's decisions for Solana\n\n")
		b.WriteString("A decision made with one of this realm's builders — the governor's own until it yields, a GovDAO proposal's execution after — sends it to the admin program on Solana with the next sequence number; the admin program records it by number and executes it after its clock. Anyone may re-dispatch an executed decision until it is recorded.\n\n")
		if hlmailbox.Live() {
			b.WriteString("- **live** since " + itoa(hlmailbox.LaunchedAt()) + "\n")
		} else {
			b.WriteString("- **not launched**: no decision is sent before the Launch decision\n")
		}
		b.WriteString("- " + decisions.GovernorLine(launchGovernor, hlmailbox.Yielded()) + "\n")
		b.WriteString("- destination: domain " + strconv.FormatUint(uint64(destination), 10) + ", recipient `" + hx(recipient[:]) + "`\n")
		if len(former) > 0 {
			parts := make([]string, len(former))
			for i, k := range former {
				parts[i] = "`" + hx(k[:]) + "`"
			}
			b.WriteString("- former recipients (retired; never a successor, never the recipient again): " + strings.Join(parts, ", ") + "\n")
		}
		b.WriteString("- launch client: `" + hx(client[:]) + "` (the pausable ISM's target; its state layout is fixed for the deployment's life at version 1 — kind 4 is reserved and refused here)\n")
		b.WriteString("- sequence: starts at " + u64s(launchSequence) + " (compiled: the predecessor's last number, 0 for a chain's first r/hlgov); last number " + u64s(last) + "; the next takes number " + u64s(last+1) + "; " + strconv.Itoa(sent.Size()) + " sent from here\n")
		b.WriteString("- " + decisions.Clocks() + " (the recipient swap's delay and every builder's deadline; Solana's clocks are the admin program's)\n")
		b.WriteString("- Solana seats as last set here:\n")
		for i := 1; i <= seatCount; i++ {
			kind := "guardian"
			if i > guardianSeats {
				kind = "watch key"
			}
			b.WriteString("  - seat " + strconv.Itoa(i) + " (" + kind + "): `" + hx(solSeats[i][:]) + "`\n")
		}
		if sent.Size() > 0 {
			b.WriteString("\n## Sent\n\n")
			sent.ReverseIterateByOffset(0, 20, func(k string, v any) bool {
				d := v.(*decision)
				b.WriteString("- #" + strings.TrimLeft(k, "0") + " kind " + strconv.Itoa(int(d.kind)) + ": " + d.text + " (sent " + strconv.Itoa(d.count) + "×, last id `" + d.id + "`)\n")
				return false
			})
		}
		b.WriteString("\n## Decisions\n\n" + ledger.Page())
		return b.String()
	case path == "json":
		fs := Former()
		for i := range fs {
			fs[i] = strconv.Quote(fs[i])
		}
		return "{\"address\":" + strconv.Quote(string(Address())) + ",\"live\":" + strconv.FormatBool(hlmailbox.Live()) +
			"," + decisions.GovernorJSON(launchGovernor, hlmailbox.Yielded()) +
			",\"destination\":" + strconv.FormatUint(uint64(destination), 10) + ",\"recipient\":" + strconv.Quote(hx(recipient[:])) + ",\"former\":[" + strings.Join(fs, ",") + "]" +
			",\"start\":" + u64s(launchSequence) + ",\"last\":" + u64s(last) + ",\"next\":" + u64s(last+1) + ",\"clocks\":" + decisions.ClocksJSON() + ",\"decisions\":" + itoa(ledger.Last()) + "}"
	case path == "decisions":
		return "# Decisions\n\n" + ledger.Page()
	case path == "decisions.json":
		return ledger.JSON()
	case strings.HasPrefix(path, "decision/"):
		n, err := strconv.ParseUint(path[len("decision/"):], 10, 64)
		if err != nil {
			return "null"
		}
		v := sent.Get(seqKey(n))
		if v == nil {
			return "null"
		}
		d := v.(*decision)
		return "{\"number\":" + u64s(n) + ",\"kind\":" + strconv.Itoa(int(d.kind)) + ",\"body\":" + strconv.Quote(hx(d.body)) +
			",\"id\":" + strconv.Quote(d.id) + ",\"count\":" + strconv.Itoa(d.count) + ",\"at\":" + itoa(d.at) + ",\"text\":" + strconv.Quote(d.text) + "}"
	}
	return "unknown path; see the page"
}
