// Package hlbubble is the BUBBLE lock: the bridge's BUBBLE route on gno.land (bridge/PLAN.md §5.2–§5.5), the same
// shape as r/hlgnot over the BUBBLE token (gno.land/r/…/bubble) instead of coins.
//
// Out. TransferRemote takes amount + fee of the caller's BUBBLE through the token's allowance (the caller approves
// this realm first), keeps the amount in the lock, pays the fee to r/hlfees, and sends a token message through
// r/hlmailbox to the synthetic BUBBLE program on Solana, which mints as much there.
//
// In. A burn on Solana comes back as a token message: Process takes it from the mailbox, checks it came from the
// enrolled router, and writes a claim in the recipient's queue; Claim pays claims in turns under the meters — a
// tenth of the lock a day (never below the floor), a quarter of that for any one recipient, the fee first. The old
// 1,000,000 BUBBLE day cap and the admin's pause are gone: the meter and the guardians' flags replace them.
//
// Who may change what. Nobody but the governor through the builders until it yields on r/hlmailbox, and GovDAO
// after (M1k); the guardians and watch keys can only pause, through r/hlmailbox. Every launch value is compiled in
// below; nothing moves until the Launch decision executes. The state machine is gno.land/p/…/hlroute/v0; this
// realm holds the BUBBLE and makes the calls.
package hlbubble

import (
	"chain"
	"chain/runtime"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlroute/v0"
	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlmailbox"
	"gno.land/r/gov/dao"
)

const (
	namespace = "gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/"
	pkgPath   = namespace + "hlbubble" // must match gnomod.toml

	mailboxPath = namespace + "hlmailbox"
	feesPath    = namespace + "hlfees"
	bubblePath  = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble" // the live token realm, never redeployed
	hlgnotPath  = namespace + "hlgnot"
	hlgovPath   = namespace + "hlgov"

	one = int64(1_000_000) // one BUBBLE in base units

	// The launch values (§5.3, §5.5). The router — the synthetic BUBBLE program on Solana — is a PLACEHOLDER (the
	// test route of the vectors) until the setup step (§5.8); bridge/local/e2e.sh swaps it for its run's.
	launchFee      = 100 * one
	launchMinimum  = 200 * one
	launchFeeFloor = 40 * one
	launchCapFloor = 10_000 * one
	launchMaximum  = 25_000 * one
	launchRouter   = "c807d773013b14cee2855ca9efafeac0b3bbc3a42fd397c2fbffda6417d290f1" // the BUBBLE token program ETqUXu1uJPj8qgmw8AJMqhgWuL5QW5ymgUMiCARbXYPA

	maxI64 = uint64(1<<63 - 1)
)

// launchGovernor is the governor (M1k): the mailbox's, compiled here too so a member reads it in this realm's
// served source; init refuses a deploy with another. bridge/local/e2e.sh swaps it for gnodev's test1.
const launchGovernor = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")

var (
	st = hlroute.New(hlroute.Launch{Symbol: "BUBBLE", Fee: launchFee, Minimum: launchMinimum, FeeFloor: launchFeeFloor,
		CapFloor: launchCapFloor, Maximum: launchMaximum, Domain: hlmailbox.LaunchOrigin(), Router: mustKey(launchRouter),
		Now: time.Now().Unix()})

	// realms are the addresses a transfer may not name as its recipient on either side (§5.2).
	realms = []address{chain.PackageAddress(pkgPath), chain.PackageAddress(mailboxPath), chain.PackageAddress(feesPath),
		chain.PackageAddress(bubblePath), chain.PackageAddress(hlgnotPath), chain.PackageAddress(hlgovPath)}
)

// init refuses a deploy whose compiled governor is not the mailbox's (M1k): the bridge's realms are governed by
// one key until it yields, or by GovDAO from the first block, never a mix.
func init() {
	if launchGovernor != hlmailbox.Governor() {
		panic("hlbubble: the compiled governor " + string(launchGovernor) + " is not the mailbox's " + string(hlmailbox.Governor()))
	}
}

func mustKey(s string) [32]byte {
	k, err := hl.ParseKey32(s)
	if err != nil {
		panic(err.Error())
	}
	return k
}

func now() int64 { return time.Now().Unix() }

func u32(n uint32) string { return strconv.FormatUint(uint64(n), 10) }
func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("hlbubble: that realm value is not live; pass your own cur")
	}
	return cur.Previous().Address()
}

func mustHex(s, what string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(s), "0x"))
	if err != nil {
		panic("hlbubble: the " + what + " is not hex")
	}
	return b
}

// isRealm is whether an address is a realm of the bridge: the six compiled here, every route realm the mailbox
// registers (R39: a successor's address is refused as a recipient at send and swept at a credit, to be credited to
// its owner by id, never paid into a realm's account outside every counter) and every one it dropped (AT6: a
// re-pointed-away successor, a route no more that nothing of the line can move BUBBLE out of). A handful of reads.
func isRealm(a address) bool {
	for _, r := range realms {
		if r == a {
			return true
		}
	}
	for _, p := range hlmailbox.Routes() {
		if chain.PackageAddress(p) == a {
			return true
		}
	}
	for _, p := range hlmailbox.DroppedRoutes() {
		if chain.PackageAddress(p) == a {
			return true
		}
	}
	return false
}

func mustBeLive() {
	if !hlmailbox.Live() {
		panic("hlbubble: not launched: nothing is sent, credited or paid before the Launch decision")
	}
}

func mustNotBePaused(fn string) {
	if hlmailbox.Paused(pkgPath, fn) {
		panic("hlbubble: " + fn + " are paused by a guardian or a watch key")
	}
}

// mustNotBeDropped refuses a realm the mailbox dropped from its line (R35): its predecessor re-pointed the migration
// to another successor while this realm had pulled nothing, so it is a route no more — Solana's token may still
// name it the router until the next kind 6, and a send or a credit here would be against a lock no realm of the
// line holds. The mailbox refuses its Dispatch and its Process too; the line's last realm takes every message
// addressed to it once its import has ended.
func mustNotBeDropped() {
	if by := hlmailbox.Dropped(pkgPath); by != "" {
		panic("hlbubble: a route no more: " + by + " re-pointed its migration to another successor; the line's last realm takes every message and send")
	}
}

func syncLaunch() {
	if la := hlmailbox.LaunchedAt(); la != st.LaunchSeen {
		st.ResetMeters(la)
		st.LaunchSeen = la
	}
}

// ------------------------------------------------------------- reading --

// Address is this realm's address: the spender to approve on the bubble realm before TransferRemote, the holder
// of the lock, and (as 32 bytes) the router the Solana program enrolls.
func Address() address { return chain.PackageAddress(pkgPath) }

// Locked is the lock: what backs synthetic BUBBLE on Solana, by the counters (sent − paid).
func Locked() int64 { return st.Lock }

// Balance is the BUBBLE this realm holds; it is the lock unless someone sent BUBBLE here outside a transfer.
func Balance() int64 { return bubble.BalanceOf(Address()) }

// Router is the enrolled router on Solana, in hex.
func Router() string { return hex.EncodeToString(st.Router[:]) }

// Domain is the Solana domain this route sends to and takes from.
func Domain() uint32 { return st.Domain }

func Fee() int64      { return st.Fee }
func Minimum() int64  { return st.Minimum }
func FeeFloor() int64 { return st.FeeFloor }
func CapFloor() int64 { return st.CapFloor }
func Maximum() int64  { return st.Maximum }
func Cap() int64      { return st.Cap() }

// Counters is the identity's five counters (§5.9): sentTotal, paidTotal, owed, voided, lost.
func Counters() (sentTotal, paidTotal, owed, voided, lost int64) {
	return st.SentTotal, st.PaidTotal, st.Owed, st.Voided, st.Lost
}

// Migrated is the successor's pkgpath once a migration applied, "" before.
func Migrated() string { return st.MigratedTo }

// ---------------------------------------------------------------- out --

// TransferRemote sends amount of the caller's BUBBLE to recipient on destination (a Solana address in base58, or
// 32 bytes in hex) and returns the message id in hex. First, on the bubble realm, the caller approves THIS realm
// (bubble.Approve, spender Address()) for at least amount + fee: the amount is locked here, the fee goes to
// r/hlfees. The amount is between the minimum and the per-message maximum.
func TransferRemote(cur realm, destination uint32, recipient string, amount int64) string {
	who := caller(cur)
	mustBeLive()
	mustNotBePaused(hlmailbox.FnSends)
	mustNotBeDropped()
	st.MustSend(hlmailbox.Predecessor(pkgPath), env(cur)) // a successor takes no send before its last page is in (R35, F28) and before kind 6 names it (AT7)
	if destination != st.Domain {
		panic("hlbubble: no route to domain " + u32(destination))
	}
	st.CheckSend(amount)
	to, err := hl.ParseKey32(recipient)
	if err != nil {
		panic(err.Error())
	}
	if to == ([32]byte{}) {
		panic("hlbubble: the recipient is all zeros")
	}
	if a, err := hl.Bytes32ToAddress(to); err == nil && isRealm(a) {
		panic("hlbubble: the recipient is a realm of the bridge")
	}
	self := Address()
	before := bubble.BalanceOf(self)
	bubble.TransferFrom(cross(cur), who, self, amount+st.Fee)
	if bubble.BalanceOf(self) != before+amount+st.Fee {
		panic("hlbubble: the lock moved by the wrong amount")
	}
	bubble.Transfer(cross(cur), chain.PackageAddress(feesPath), st.Fee)
	id := hlmailbox.Dispatch(cross(cur), destination, st.Router, hl.TokenMessage(to, uint64(amount), nil))
	idHex := hex.EncodeToString(id[:])
	st.Send(now(), idHex, who, amount)
	chain.Emit("SentTransferRemote",
		"destination", u32(destination),
		"recipient", hex.EncodeToString(to[:]),
		"amount", itoa(amount),
		"fee", itoa(st.Fee),
		"from", string(who),
		"id", idHex,
	)
	return idHex
}

// ----------------------------------------------------------------- in --

// Process takes a token message from Solana and credits a claim to its recipient. Anyone may call it with the
// verifier's metadata and the message, both in hex. A refused message stays undelivered. A realm registered as a
// successor credits nothing — its own messages included (R32) — before the last page of its predecessor's
// migration is in (AQ1); a migrated realm refuses before the mailbox is asked (see hlgnot's).
func Process(cur realm, metadata, message string) {
	caller(cur)
	mustBeLive()
	mustNotBePaused(hlmailbox.FnCredits)
	mustNotBeDropped()
	msg := mustHex(message, "message")
	m, err := hl.ParseMessage(msg)
	if err != nil {
		panic(err.Error())
	}
	if st.Migrated() {
		panic("hlbubble: migrated to " + st.MigratedTo + ": the successor takes this message")
	}
	if self, err := hl.AddressToBytes32(Address()); err != nil {
		panic(err.Error())
	} else {
		st.MustTake(m.Recipient == self, hlmailbox.Predecessor(pkgPath))
	}
	t := now()
	if m.Origin != st.Domain || !st.RouterAccepts(t, m.Sender) {
		panic("hlbubble: the message is not from the router enrolled for domain " + u32(st.Domain))
	}
	rcpt, amount, _, err := hl.ParseTokenMessage(m.Body)
	if err != nil {
		panic(err.Error())
	}
	if amount > maxI64 {
		panic("hlbubble: the amount is past what BUBBLE can hold")
	}
	origin, sender, body := hlmailbox.Process(cross(cur), mustHex(metadata, "metadata"), msg)
	if origin != m.Origin || sender != m.Sender || string(body) != string(m.Body) {
		panic("hlbubble: the mailbox read the message differently") // cannot happen: the same bytes, the same parser
	}
	// a recipient that is no gno address (its top twelve bytes not zero, §13) or a realm of the bridge is swept:
	// owed, paying nobody until GovDAO credits it by id to its owner
	to, err := hl.Bytes32ToAddress(rcpt)
	recipient := string(to)
	if err != nil {
		recipient = hex.EncodeToString(rcpt[:])
	}
	idb := hl.ID(msg)
	id := hex.EncodeToString(idb[:])
	epoch, _ := hlmailbox.PayoutsEpoch(pkgPath)
	swept := st.Credit(t, runtime.ChainHeight(), epoch, id, to, int64(amount), hlroute.BySigners, err != nil || isRealm(to))
	chain.Emit("Credited",
		"origin", u32(origin),
		"recipient", recipient,
		"amount", itoa(int64(amount)),
		"id", id,
		"swept", strconv.FormatBool(swept),
	)
}

// Claim pays up to n claims (n ≤ 20) taking recipients in turns under the meters, the fee as each claim's first
// installment. Anyone may call it; the relayers do. It returns how many claims it paid something on.
func Claim(cur realm, n int) int {
	caller(cur)
	mustBeLive()
	mustNotBePaused(hlmailbox.FnPayouts)
	mustNotBeDropped()
	syncLaunch()
	epoch, at := hlmailbox.PayoutsEpoch(pkgPath)
	paid := st.Claim(now(), n, epoch, at, env(cur))
	chain.Emit("Claimed", "count", strconv.Itoa(paid))
	return paid
}

func pay(cur realm, to address, amount int64) { bubble.Transfer(cross(cur), to, amount) }

func env(cur realm) hlroute.Env {
	return hlroute.Env{
		Flagged:    func(id string, height int64, verifier bool) bool { return hlmailbox.Flagged(pkgPath, id, height, verifier) },
		ClearFlags: func(fn string) bool { return hlmailbox.ClearFlags(cross(cur), fn) },
		RemoveSeat: func(seat int, holder address) bool { return hlmailbox.VacateSeat(cross(cur), seat, holder) },
		Delivered:  func(id string) bool { return hlmailbox.Delivered(id) != 0 },
		MarkDone:   func(id string) { hlmailbox.MarkDone(cross(cur), id) },
		Epoch:      func() int64 { e, _ := hlmailbox.PayoutsEpoch(pkgPath); return e },
		Height:     func() int64 { return runtime.ChainHeight() },
		Pay:        func(to address, amount int64) { pay(cur, to, amount) },
		PayFee:     func(amount int64) { pay(cur, chain.PackageAddress(feesPath), amount) },
		AddRoute:     func(path string) { hlmailbox.AddRoute(cross(cur), path) },
		AnnouncedFor: func(path string) string { return hlmailbox.SuccessorFor(path) },
		Predecessor:  func() string { return hlmailbox.Predecessor(pkgPath) },
		IsRoute:      func(path string) bool { return hlmailbox.IsRoute(path) },
		Enrolled:     func() (int64, int64) { return hlmailbox.Enrolled(pkgPath) },
	}
}

// ------------------------------------------------------------ builders --

// The builders (§5.3): the same as r/hlgnot's, amounts in BUBBLE base units. A decision made with one of them —
// the governor's through Govern until it yields on r/hlmailbox, a GovDAO proposal's after (M1k) — is the only way
// a setting changes; see hlgnot's for the clocks and the Request.

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
			panic("hlbubble: only " + decisions.DAOPath + " executes a decision, not " + who(prev.PkgPath(), prev.Address()))
		}
		return
	}
	if !prev.IsUser() || prev.Address() != launchGovernor {
		panic("hlbubble: until the governor yields, " + string(launchGovernor) + " alone decides, by Govern from its own key: not " + who(prev.PkgPath(), prev.Address()) + " (a GovDAO proposal is refused until the yield)")
	}
}

func propose(cur realm, d hlroute.Draft) Request {
	if !cur.IsCurrent() {
		panic("hlbubble: that realm value is not live; pass your own cur")
	}
	made := now()
	cb := func(cur realm) error {
		mustBeGovernor(cur)
		t := now()
		if err := decisions.Expired(made, t); err != nil {
			return err
		}
		if d.Kind != hlroute.KindCancel {
			mustBeLive()
		}
		if d.Kind == hlroute.KindApplyRefund {
			mustNotBePaused(hlmailbox.FnPayouts) // a refund moves BUBBLE out of the lock: under a standing payouts flag it waits like a claim (§5.9; the proposal survives for a retry)
		}
		dec := st.Decide(made, t, d, env(cur))
		chain.Emit("Decision", "id", itoa(dec.ID), "kind", dec.Kind, "state", dec.State())
		return nil
	}
	return Request{proposal: dao.NewProposalRequest("hlbubble: "+d.Kind, d.Text, dao.NewSimpleExecutor(0, cur, cb, d.Text)), text: d.Text, decide: cb}
}

// Govern is the governor's way in before the yield (M1k): the same closure GovDAO's proxy runs after it, called
// non-crossing in this frame so it reads the governor from cur.Previous(); refused for anyone else and for
// everyone once the governor yielded on r/hlmailbox (or when none was compiled); see hlgnot's.
func Govern(cur realm, r Request) {
	if !cur.IsCurrent() {
		panic("hlbubble: that realm value is not live; pass your own cur")
	}
	if r.decide == nil {
		panic("hlbubble: not a builder's request")
	}
	if yielded := hlmailbox.Yielded(); decisions.DAOGoverns(launchGovernor, yielded) {
		if launchGovernor == "" {
			panic("hlbubble: no governor was compiled, " + decisions.DAOPath + " governs from the first block: a decision is a GovDAO proposal, never Govern")
		}
		panic("hlbubble: the governor yielded at height " + itoa(yielded) + ", " + decisions.DAOPath + " governs since: a decision is a GovDAO proposal, never Govern")
	}
	mustBeGovernor(cur)
	if err := r.decide(cur); err != nil {
		panic("hlbubble: " + err.Error())
	}
}

func NewSetCapFloorRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftCapFloor(n))
}

func NewSetMaximumRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftMaximum(n))
}

func NewSetFeeRequest(cur realm, fee, minimum int64) Request {
	mustBeLive()
	return propose(cur, st.DraftFee(fee, minimum))
}

func NewSetFeeFloorRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftFeeFloor(n))
}

func NewSetRouterRequest(cur realm, router string) Request {
	mustBeLive()
	return propose(cur, st.DraftRouter(mustKey(router), router))
}

// NewVoidRequest voids credits by message id (a claim, or a sweep entry as forged) or by a range of credits
// ("heights:<from>-<to>" or "since:<from>", closed at the height the proposal is made, at most 1,000 credits), as
// withheld or forged, with the unpause option (the seats' holders recorded; a seat whose occupant changed by
// execution is skipped): see hlgnot's.
func NewVoidRequest(cur realm, ids string, forged bool, unpauseFns, removeSeats string) Request {
	mustBeLive()
	return propose(cur, st.DraftVoid(ids, forged, unpauseFns, removeSeats, runtime.ChainHeight(), hlmailbox.Seat))
}

func NewRestoreRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftRestore(ids))
}

func NewCreditRequest(cur realm, id string, to address, amount int64) Request {
	mustBeLive()
	if !to.IsValid() || isRealm(to) {
		panic("hlbubble: the recipient must be an address outside the bridge's realms")
	}
	return propose(cur, st.DraftCredit(id, to, amount, hlmailbox.Delivered(id) != 0))
}

// NewSweepRequest pays sweep entries, named by message id, to an address after 7 days — their sum, at most the
// lock — and drops them (R19): see hlgnot's.
func NewSweepRequest(cur realm, ids string, to address) Request {
	mustBeLive()
	if !to.IsValid() || isRealm(to) {
		panic("hlbubble: the recipient must be an address outside the bridge's realms")
	}
	return propose(cur, st.DraftSweep(ids, to))
}

// NewRefundRequest queues a refund of imported sends by id, 7 days, once kind 6 has enrolled this realm on Solana
// for 14 days (AR1, R37); applied then by NewApplyRefundRequest, never by Execute (AT2); see hlgnot's.
func NewRefundRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftRefund(ids, now(), env(cur)))
}

// NewApplyRefundRequest applies a queued refund decision whose 7 days have passed, at once (AT2): GovDAO's own act
// after hlwatch's check that the token's router on Solana is this realm; under a standing payouts flag it waits
// like a claim; see hlgnot's.
func NewApplyRefundRequest(cur realm, id int64) Request {
	mustBeLive()
	return propose(cur, st.DraftApplyRefund(id, now(), env(cur)))
}

// NewWriteOffRequest books refunded sends delivered on Solana after their refund as lost, after 7 days (AR1); see
// hlgnot's.
func NewWriteOffRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftWriteOff(ids))
}

// NewMigrateRequest: a successor that announced itself to the mailbox for the BUBBLE route (R25, AQ5) and is no
// route already (R31), after 7 days; a realm that succeeds another migrates on only once its own import has ended
// (R31); see hlgnot's.
func NewMigrateRequest(cur realm, to string) Request {
	mustBeLive()
	return propose(cur, st.DraftMigrate(to, pkgPath, env(cur)))
}

func NewCancelRequest(cur realm, id int64) Request {
	return propose(cur, st.DraftCancel(id))
}

// Execute applies a queued decision whose 7 days have passed. Anyone may call it. A sweep payment moves BUBBLE
// out of the lock, so under a standing payouts flag it waits for the unpause like a claim (§5.9). A refund is never
// Execute's (AT2): the state refuses the kind, and GovDAO applies it by NewApplyRefundRequest.
func Execute(cur realm, id int64) {
	caller(cur)
	mustBeLive()
	if d := st.Ledger.Get(id); d != nil && d.Kind == hlroute.KindSweep {
		mustNotBePaused(hlmailbox.FnPayouts)
	}
	dec := st.Execute(now(), id, env(cur))
	chain.Emit("Decision", "id", itoa(dec.ID), "kind", dec.Kind, "state", dec.State())
}

// Pull is the successor's: once a migrate decision names it, the realm at that pkgpath calls Pull from its own
// code, page by page from 0, and receives the lock (transferred to its address, with page 0) and the records to
// import, up to 500 a page (the snapshot's More says whether a page follows); a page pulled already hands over
// nothing. Page 0 moves the lock, so under a standing payouts flag it waits for the unpause like a sweep payment
// (R27, R16); the flag follows the claims to the successor (hlmailbox.AddRoute).
func Pull(cur realm, page int) *hlroute.Snapshot {
	if !cur.IsCurrent() {
		panic("hlbubble: that realm value is not live; pass your own cur")
	}
	path := cur.Previous().PkgPath()
	if st.MigratedTo == "" || path != st.MigratedTo {
		panic("hlbubble: only the successor named by a migrate decision pulls")
	}
	if page == 0 {
		mustNotBePaused(hlmailbox.FnPayouts)
	}
	snap := st.Export(page, hlroute.PullPage)
	if page == 0 {
		hlmailbox.NotePulled(cross(cur), path) // the lock moved: the mailbox answers Pulled (R35) — kind 6 may enrol the successor, and the migration is never re-pointed
	}
	if snap.Lock > 0 {
		pay(cur, chain.PackageAddress(path), snap.Lock)
	}
	chain.Emit("Migrated", "to", path, "page", strconv.Itoa(page), "lock", itoa(snap.Lock), "claims", strconv.Itoa(len(snap.Claims)), "sweeps", strconv.Itoa(len(snap.Sweeps)), "sends", strconv.Itoa(len(snap.Sends)), "more", strconv.FormatBool(snap.More))
	return snap
}

// --------------------------------------------------------------- pages --

func pausedText() string {
	var fns []string
	for _, fn := range []string{hlmailbox.FnSends, hlmailbox.FnCredits, hlmailbox.FnPayouts} {
		if hlmailbox.Paused(pkgPath, fn) {
			fns = append(fns, fn)
		}
	}
	return strings.Join(fns, ", ")
}

// Render: "" the route's page; "decisions"; "json"; "decisions.json"; "claim/<id>"; "send/<id>"; "claims/<from>",
// "sweeps/<from>" and "refunds/<from>", up to 100 entries a page (hlgnot's Render says more).
func Render(path string) string {
	epoch, at := hlmailbox.PayoutsEpoch(pkgPath)
	switch {
	case strings.HasPrefix(path, "claims/"):
		return st.ClaimsPage(parseFrom(path[len("claims/"):]))
	case strings.HasPrefix(path, "sweeps/"):
		return st.SweepsPage(parseFrom(path[len("sweeps/"):]))
	case strings.HasPrefix(path, "send/"):
		return st.SendJSON(path[len("send/"):])
	case strings.HasPrefix(path, "refunds/"):
		return st.RefundsPage(parseFrom(path[len("refunds/"):]))
	case path == "":
		var b strings.Builder
		b.WriteString("# BUBBLE across chains\n\n")
		b.WriteString("The bridge's BUBBLE route on gno.land. BUBBLE sent to Solana is locked here, and the synthetic BUBBLE there is backed by it one to one; a burn there is credited here as a claim, paid under the meters. Every setting moves only by a decision made with this realm's builders — the governor's own until it yields, a GovDAO proposal after.\n\n")
		if hlmailbox.Live() {
			b.WriteString("- **live** since " + itoa(hlmailbox.LaunchedAt()) + "\n")
		} else {
			b.WriteString("- **not launched**: the values below are the compiled launch values, waiting for the Launch decision\n")
		}
		b.WriteString("- " + decisions.GovernorLine(launchGovernor, hlmailbox.Yielded()) + "\n")
		b.WriteString("- balance: " + st.Amount(Balance()) + "\n")
		b.WriteString(st.Figures(now(), epoch, at, hlmailbox.LaunchedAt(), pausedText()))
		b.WriteString("\n## Decisions\n\n" + st.Ledger.Page())
		return b.String()
	case path == "decisions":
		return "# Decisions\n\n" + st.Ledger.Page()
	case path == "json":
		return "{\"address\":" + strconv.Quote(string(Address())) + ",\"live\":" + strconv.FormatBool(hlmailbox.Live()) +
			"," + decisions.GovernorJSON(launchGovernor, hlmailbox.Yielded()) +
			",\"balance\":" + itoa(Balance()) + ",\"paused\":" + strconv.Quote(pausedText()) + "," + st.JSON(now(), epoch, at, hlmailbox.LaunchedAt()) + "}"
	case path == "decisions.json":
		return st.Ledger.JSON()
	case strings.HasPrefix(path, "claim/"):
		return st.ClaimJSON(path[len("claim/"):])
	}
	return "unknown path; see the route's page"
}

// parseFrom reads a page's offset; -1 (an empty page) for anything but a number.
func parseFrom(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return -1
	}
	return n
}
