// Package hlgnot is the GNOT lock: the bridge's GNOT route on gno.land (bridge/PLAN.md §5.2, §5.4, §5.5).
//
// Out. TransferRemote takes the coins a direct user call sends — exactly amount + fee in ugnot — keeps the amount
// in the lock, pays the fee to r/hlfees, and sends a token message through r/hlmailbox to the synthetic GNOT
// program on Solana, which mints as much there.
//
// In. A burn on Solana comes back as a token message: Process takes it from the mailbox (which checks the active
// verifier and that it was never delivered), checks it came from the enrolled router, and writes a claim in the
// recipient's queue — never a payment on the spot. Claim pays claims in turns under the meters: a tenth of the
// lock a day (never below the floor), a quarter of that for any one recipient, the fee as the first installment,
// from a meter that starts empty at launch and after every unpause that clears a payouts flag. A burn below the
// fee, or to a realm address, is credited to the sweep queue, which only a GovDAO decision pays.
//
// Who may change what. Nobody: every setting moves by a decision made with the builders below (the fee and
// minimum, the fee floor, the cap floor, the per-message maximum, the router; a void, a restore or a credit by
// message id; a sweep payment; a refund by id; a migration to a successor), at once or after 7 days as §5.3 says —
// the governor's own decision through Govern until it yields on r/hlmailbox, a GovDAO proposal's after (M1k);
// the guardians and watch keys can only pause (sends, credits, payouts) through r/hlmailbox. Every launch value is
// compiled in below and written at deploy; nothing is sent or credited until the Launch decision executes.
//
// The state machine — claims, meters, counters, the identity of §5.9 — is gno.land/p/…/hlroute/v0; this realm
// holds the coins and makes the calls.
package hlgnot

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlroute/v0"
	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlmailbox"
	"gno.land/r/gov/dao"
)

const (
	namespace = "gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/"
	pkgPath   = namespace + "hlgnot" // must match gnomod.toml

	mailboxPath  = namespace + "hlmailbox"
	feesPath     = namespace + "hlfees"
	bubblePath   = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble" // the live token realm, never redeployed
	hlbubblePath = namespace + "hlbubble"
	hlgovPath    = namespace + "hlgov"

	gnot = int64(1_000_000) // one GNOT in ugnot

	// The launch values (§5.3, §5.5): the fee, the minimum, the fee floor, the cap floor, the per-message maximum,
	// and the router — the synthetic GNOT program on Solana. The router is a PLACEHOLDER (the test route of the
	// vectors) until the setup step (§5.8) gives the program id; bridge/local/e2e.sh swaps it for its run's.
	launchFee      = 5 * gnot
	launchMinimum  = 10 * gnot
	launchFeeFloor = 2 * gnot
	launchCapFloor = 10_000 * gnot
	launchMaximum  = 25_000 * gnot
	launchRouter   = "9c79e6474d5e4cb2e1bb479df49c8d7c0244af0bb1cf452aa573386632894895" // the GNOT token program BXpQkFcsHEsqVxvFQ2e4VSgfDSNBCKQsuKx9Qd2xtKj2

	maxI64 = uint64(1<<63 - 1)
)

// launchGovernor is the governor (M1k): the mailbox's, compiled here too so a member reads it in this realm's
// served source; init refuses a deploy with another. bridge/local/e2e.sh swaps it for gnodev's test1.
const launchGovernor = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")

var (
	st = hlroute.New(hlroute.Launch{Symbol: "GNOT", Fee: launchFee, Minimum: launchMinimum, FeeFloor: launchFeeFloor,
		CapFloor: launchCapFloor, Maximum: launchMaximum, Domain: hlmailbox.LaunchOrigin(), Router: mustKey(launchRouter),
		Now: time.Now().Unix()})

	// realms are the addresses a transfer may not name as its recipient on either side (§5.2): a burn to one of
	// them goes to the sweep queue, a send to one is refused.
	realms = []address{chain.PackageAddress(pkgPath), chain.PackageAddress(mailboxPath), chain.PackageAddress(feesPath),
		chain.PackageAddress(bubblePath), chain.PackageAddress(hlbubblePath), chain.PackageAddress(hlgovPath)}
)

// init refuses a deploy whose compiled governor is not the mailbox's (M1k): the bridge's realms are governed by
// one key until it yields, or by GovDAO from the first block, never a mix.
func init() {
	if launchGovernor != hlmailbox.Governor() {
		panic("hlgnot: the compiled governor " + string(launchGovernor) + " is not the mailbox's " + string(hlmailbox.Governor()))
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
		panic("hlgnot: that realm value is not live; pass your own cur")
	}
	return cur.Previous().Address()
}

func mustHex(s, what string) []byte {
	b, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(s), "0x"))
	if err != nil {
		panic("hlgnot: the " + what + " is not hex")
	}
	return b
}

// isRealm is whether an address is a realm of the bridge: the six compiled here, every route realm the mailbox
// registers (R39) and every one it dropped (AT6: a re-pointed-away successor, a route no more that nothing of the
// line can move coins out of) — a successor's address, which its page prints as the lock's holder and a holder
// pastes as a deposit address, is refused as a recipient at send and swept at a credit, to be credited to its
// owner by id, never paid into a realm's account outside every counter. A handful of reads.
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
		panic("hlgnot: not launched: nothing is sent, credited or paid before the Launch decision")
	}
}

func mustNotBePaused(fn string) {
	if hlmailbox.Paused(pkgPath, fn) {
		panic("hlgnot: " + fn + " are paused by a guardian or a watch key")
	}
}

// mustNotBeDropped refuses a realm the mailbox dropped from its line (R35): its predecessor re-pointed the migration
// to another successor while this realm had pulled nothing, so it is a route no more — Solana's token may still
// name it the router until the next kind 6, and a send or a credit here would be against a lock no realm of the
// line holds. The mailbox refuses its Dispatch and its Process too; the line's last realm takes every message
// addressed to it once its import has ended.
func mustNotBeDropped() {
	if by := hlmailbox.Dropped(pkgPath); by != "" {
		panic("hlgnot: a route no more: " + by + " re-pointed its migration to another successor; the line's last realm takes every message and send")
	}
}

// syncLaunch empties the meters at the launch, once: they start empty there as at a deploy (§5.4).
func syncLaunch() {
	if la := hlmailbox.LaunchedAt(); la != st.LaunchSeen {
		st.ResetMeters(la)
		st.LaunchSeen = la
	}
}

// ------------------------------------------------------------- reading --

// Address is this realm's address: the holder of the lock, and (as 32 bytes) the router the Solana program enrolls.
func Address() address { return chain.PackageAddress(pkgPath) }

// Locked is the lock: what backs synthetic GNOT on Solana, by the counters (sent − paid).
func Locked() int64 { return st.Lock }

// Balance is the ugnot this realm's account holds; it is the lock unless someone sent coins here outside a transfer.
func Balance() int64 { return banker.NewReadonlyBanker().GetCoin(Address(), "ugnot") }

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

// TransferRemote sends amount of GNOT to recipient on destination (a Solana address in base58, or 32 bytes in
// hex) and returns the message id in hex. The call must be a direct user call sending exactly amount + fee in
// ugnot: the amount is locked here, the fee goes to r/hlfees. The amount is between the minimum and the
// per-message maximum; a realm's address as recipient is refused.
func TransferRemote(cur realm, destination uint32, recipient string, amount int64) string {
	mustBeLive()
	mustNotBePaused(hlmailbox.FnSends)
	mustNotBeDropped()
	st.MustSend(hlmailbox.Predecessor(pkgPath), env(cur)) // a successor takes no send before its last page is in (R35, F28) and before kind 6 names it (AT7)
	if destination != st.Domain {
		panic("hlgnot: no route to domain " + u32(destination))
	}
	st.CheckSend(amount)
	to, err := hl.ParseKey32(recipient)
	if err != nil {
		panic(err.Error())
	}
	if to == ([32]byte{}) {
		panic("hlgnot: the recipient is all zeros")
	}
	if a, err := hl.Bytes32ToAddress(to); err == nil && isRealm(a) {
		panic("hlgnot: the recipient is a realm of the bridge")
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("hlgnot: a direct user call only")
	}
	want := amount + st.Fee
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != want {
		panic("hlgnot: send exactly " + itoa(want) + "ugnot (the amount plus the fee of " + itoa(st.Fee) + "), not " + sent.String())
	}
	runtime.AssertOriginCall() // a direct MsgCall, so the envelope landed here and nothing ran in between
	who := prev.Address()
	banker.NewBanker(banker.BankerTypeOriginSend, cur).SendCoins(Address(), chain.PackageAddress(feesPath), chain.Coins{{"ugnot", st.Fee}})
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

// Process takes a token message from Solana and credits a claim to its recipient. Anyone may call it — a relayer,
// usually — with the verifier's metadata and the message, both in hex. The mailbox checks the verifier and that
// the message was never delivered; this checks it came from the enrolled router (the old one too, for 7 days after
// a swap). A refused message stays undelivered and can be brought again. A realm registered as a successor credits
// nothing before the last page of its predecessor's migration is in (R32) — a message addressed to itself as much
// as one addressed to the predecessor (AQ1: the mailbox hands a migrated route's messages to its successor) — and
// a migrated realm refuses before the mailbox is asked: the successor takes it.
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
		panic("hlgnot: migrated to " + st.MigratedTo + ": the successor takes this message")
	}
	if self, err := hl.AddressToBytes32(Address()); err != nil {
		panic(err.Error())
	} else {
		st.MustTake(m.Recipient == self, hlmailbox.Predecessor(pkgPath))
	}
	t := now()
	if m.Origin != st.Domain || !st.RouterAccepts(t, m.Sender) {
		panic("hlgnot: the message is not from the router enrolled for domain " + u32(st.Domain))
	}
	rcpt, amount, _, err := hl.ParseTokenMessage(m.Body)
	if err != nil {
		panic(err.Error())
	}
	if amount > maxI64 {
		panic("hlgnot: the amount is past what GNOT can hold")
	}
	origin, sender, body := hlmailbox.Process(cross(cur), mustHex(metadata, "metadata"), msg)
	if origin != m.Origin || sender != m.Sender || string(body) != string(m.Body) {
		panic("hlgnot: the mailbox read the message differently") // cannot happen: the same bytes, the same parser
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

func pay(cur realm, to address, amount int64) {
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(Address(), to, chain.Coins{{"ugnot", amount}})
}

// env is what the state machine asks of this realm.
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

// The builders (§5.3): a decision made with one of these is the only way a setting changes — the governor's own,
// through Govern, until it yields on r/hlmailbox (M1k):
//
//	hlgnot.Govern(cross(cur), hlgnot.NewSetCapFloorRequest(cross(cur), 12_000_000_000))
//
// and a GovDAO proposal after:
//
//	req := hlgnot.NewSetCapFloorRequest(cross(cur), 12_000_000_000)
//	dao.MustCreateProposal(cross(cur), req.Proposal())
//
// Each checks its parameters, writes them as the proposal's description, and returns a Request whose closure —
// the one closure, run by the governor through Govern or by GovDAO's proxy when the proposal executes — records
// the decision and settles its at-once test against the live state: a lowering, a cancel, a restore of a withheld
// claim and the void of ids a guardian's standing payouts flag names apply at once; a raise, a swap, a credit, a
// sweep payment, a migration, a void of unnamed ids and a restore of a forged claim wait 7 days, and anyone
// applies them with Execute(id); a refund waits 7 days too and is then applied by the governor's (GovDAO's, after
// the yield) own at-once decision (NewApplyRefundRequest, AT2), never by Execute. Before the Launch decision only
// cancel is proposed.

// Request is what a builder returns (M1k): the proposal GovDAO's proxy executes after the yield (Proposal), and
// the same decision the governor runs directly before it (Govern). The closure is one; only who may run it
// changes with the yield. A Request comes from a builder alone — the type is this realm's and the closure
// unexported, so no other code can build one or change what it decides — and a stranger holding one can only
// hand it back to Govern, which refuses everyone but the governor.
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

// mustBeGovernor is a decision's identity check (M1k), read from the closure's own live cur: until the governor
// yields on r/hlmailbox, the governor's own call — the compiled address, by its own transaction (cur.Previous() a
// user realm: a MsgCall's, or a MsgRun script's ephemeral realm, whose address is the signer's; never another
// realm), which is Govern's non-crossing call of the closure — and gno.land/r/gov/dao's proposals refused; after
// it, or when no governor was compiled, the proxy's exact pkgpath, as before M1k, and the governor refused like
// anyone. A refusal is a panic: a proposal made before the yield survives for a retry after it, within its 14
// days.
func mustBeGovernor(cur realm) {
	prev := cur.Previous()
	if decisions.DAOGoverns(launchGovernor, hlmailbox.Yielded()) {
		if p := prev.PkgPath(); p != decisions.DAOPath {
			panic("hlgnot: only " + decisions.DAOPath + " executes a decision, not " + who(prev.PkgPath(), prev.Address()))
		}
		return
	}
	if !prev.IsUser() || prev.Address() != launchGovernor {
		panic("hlgnot: until the governor yields, " + string(launchGovernor) + " alone decides, by Govern from its own key: not " + who(prev.PkgPath(), prev.Address()) + " (a GovDAO proposal is refused until the yield)")
	}
}

func propose(cur realm, d hlroute.Draft) Request {
	if !cur.IsCurrent() {
		panic("hlgnot: that realm value is not live; pass your own cur")
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
			mustNotBePaused(hlmailbox.FnPayouts) // a refund moves coins out of the lock: under a standing payouts flag it waits like a claim (§5.9; the proposal survives for a retry)
		}
		dec := st.Decide(made, t, d, env(cur))
		chain.Emit("Decision", "id", itoa(dec.ID), "kind", dec.Kind, "state", dec.State())
		return nil
	}
	return Request{proposal: dao.NewProposalRequest("hlgnot: "+d.Kind, d.Text, dao.NewSimpleExecutor(0, cur, cb, d.Text)), text: d.Text, decide: cb}
}

// Govern is the governor's way in before the yield (M1k): the governor — the compiled launchGovernor, by its own
// transaction (the MsgRun script that makes the request in the same transaction; never through another realm) —
// makes a builder's decision directly, the same closure GovDAO's proxy runs after the yield: the same checks, the
// same at-once test, the same 7-day queue and 14-day deadline, the same record and events. The closure is called
// non-crossing, in this frame, so it reads the governor from cur.Previous() as it reads the proxy after the yield.
// Refused for anyone else, and for everyone once the governor yielded on r/hlmailbox (or when none was compiled):
// GovDAO's proposals decide then. A request past its 14 days is refused (the deadline error) and made afresh.
func Govern(cur realm, r Request) {
	if !cur.IsCurrent() {
		panic("hlgnot: that realm value is not live; pass your own cur")
	}
	if r.decide == nil {
		panic("hlgnot: not a builder's request")
	}
	if yielded := hlmailbox.Yielded(); decisions.DAOGoverns(launchGovernor, yielded) {
		if launchGovernor == "" {
			panic("hlgnot: no governor was compiled, " + decisions.DAOPath + " governs from the first block: a decision is a GovDAO proposal, never Govern")
		}
		panic("hlgnot: the governor yielded at height " + itoa(yielded) + ", " + decisions.DAOPath + " governs since: a decision is a GovDAO proposal, never Govern")
	}
	mustBeGovernor(cur)
	if err := r.decide(cur); err != nil {
		panic("hlgnot: " + err.Error())
	}
}

// NewSetCapFloorRequest sets the day cap's floor (in ugnot): a lowering at once, never below the launch floor; a
// raise after 7 days.
func NewSetCapFloorRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftCapFloor(n))
}

// NewSetMaximumRequest sets the per-message maximum (in ugnot), never below the minimum: a lowering at once, a
// raise after 7 days.
func NewSetMaximumRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftMaximum(n))
}

// NewSetFeeRequest sets the fee and the minimum together (in ugnot), the fee not below the fee floor: lowering
// both at once, raising either after 7 days.
func NewSetFeeRequest(cur realm, fee, minimum int64) Request {
	mustBeLive()
	return propose(cur, st.DraftFee(fee, minimum))
}

// NewSetFeeFloorRequest sets the fee floor (in ugnot), not above the fee: a lowering at once, a raise after 7 days.
func NewSetFeeFloorRequest(cur realm, n int64) Request {
	mustBeLive()
	return propose(cur, st.DraftFeeFloor(n))
}

// NewSetRouterRequest swaps the router (a Solana program id in base58, or 32 bytes in hex) after 7 days; the old
// router's messages stay accepted for 7 days more.
func NewSetRouterRequest(cur realm, router string) Request {
	mustBeLive()
	return propose(cur, st.DraftRouter(mustKey(router), router))
}

// NewVoidRequest voids credits by message id (comma separated, up to 256; a claim, or a sweep entry as forged) or
// by a range of credits ("heights:<from>-<to>", every credit at those block heights; "since:<from>", every credit
// the verifier made from that height on), closed at the height the proposal is made and covering at most 1,000
// credits (a bigger range is split by heights), as withheld (the remainder stays booked, restorable) or as forged
// (the remainder dropped, the paid part lost; a sweep entry's amount dropped from what is owed). A credit a
// guardian's standing payouts flag names — by id, or by a range covering it — is voided the moment the proposal
// executes; the rest wait 7 days. The unpause option takes the unpause builder's parameters — the functions whose
// flags to clear (sends, credits, payouts; comma separated, "" for none) and the seats to vacate (comma separated,
// "" for none; each seat's holder now is recorded, and a seat whose occupant changed by execution is skipped) —
// applied in the same closure, after the void.
func NewVoidRequest(cur realm, ids string, forged bool, unpauseFns, removeSeats string) Request {
	mustBeLive()
	return propose(cur, st.DraftVoid(ids, forged, unpauseFns, removeSeats, runtime.ChainHeight(), hlmailbox.Seat))
}

// NewRestoreRequest restores voided claims by message id: a withheld one at once, a forged one after 7 days.
func NewRestoreRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftRestore(ids))
}

// NewCreditRequest credits a claim by hand after 7 days: amount (in ugnot) to a recipient under a message id. It
// marks the id done and refuses an id already done, unless that id's claim stands voided, in which case the claim
// is restored and its remainder replaced by this recipient and amount at the back of the recipient's queue.
func NewCreditRequest(cur realm, id string, to address, amount int64) Request {
	mustBeLive()
	if !to.IsValid() || isRealm(to) {
		panic("hlgnot: the recipient must be an address outside the bridge's realms")
	}
	return propose(cur, st.DraftCredit(id, to, amount, hlmailbox.Delivered(id) != 0))
}

// NewSweepRequest pays sweep entries, named by message id (comma separated, up to 256), to an address after 7
// days: their sum, at most the lock. The paid entries are dropped (R19), so none is ever paid, credited by id or
// voided twice; an entry voided or gone by then is skipped, the decision's note saying so.
func NewSweepRequest(cur realm, ids string, to address) Request {
	mustBeLive()
	if !to.IsValid() || isRealm(to) {
		panic("hlgnot: the recipient must be an address outside the bridge's realms")
	}
	return propose(cur, st.DraftSweep(ids, to))
}

// NewRefundRequest queues a refund of sends by message id (comma separated) to their senders, 7 days: the cure for
// sends a migration stranded undelivered — the sends imported from the predecessor, once kind 6 has enrolled this
// realm on Solana for 14 days by r/hlgov's note with the mailbox (AR1, R37: a refunded send stays deliverable
// there until the predecessor's router is replaced), checked when the proposal is made and when it applies. After
// the 7 days GovDAO applies it by NewApplyRefundRequest (AT2), never anyone by Execute.
func NewRefundRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftRefund(ids, now(), env(cur)))
}

// NewApplyRefundRequest applies a queued refund decision whose 7 days have passed, at once (AT2): GovDAO's own act,
// the member having read hlwatch's gate first — the token's router on Solana is this realm and the kind 6 is
// executed there — since this realm cannot see Solana, and a refund applied while the predecessor is still the
// router lets the refunded sender deliver his send there after it (minted twice, AR1); Execute refuses a refund.
// The apply is the delay's own: the note's 14 days asked again, the sum at most the lock; under a standing
// payouts flag it waits for the unpause like a claim (the closure refuses, the proposal retried within its 14
// days). Refused for a decision that is no refund, not pending, or not yet due; the description names the refund
// decision and carries its text, the ids included.
func NewApplyRefundRequest(cur realm, id int64) Request {
	mustBeLive()
	return propose(cur, st.DraftApplyRefund(id, now(), env(cur)))
}

// NewWriteOffRequest books refunded sends, by message id (comma separated), as lost after 7 days (AR1): a refunded
// send delivered on Solana after all (a stranger's Reemit) minted a second time against nothing, and the write-off
// closes the identity by its amount; only a refunded send, once — the member reads hlwatch's DELIVERED line for the
// id first.
func NewWriteOffRequest(cur realm, ids string) Request {
	mustBeLive()
	return propose(cur, st.DraftWriteOff(ids))
}

// NewMigrateRequest hands the lock, the claims and the send records to a successor realm after 7 days: the
// successor then calls Pull from its own code and takes them over. The successor must have announced itself to
// the mailbox from its own code first, for the GNOT route (hlmailbox.AnnounceSuccessor(cur, "GNOT"), R25 and
// AQ5), and must not be a route the mailbox registers already (R31) — checked when the proposal is made and when
// it applies, so the lock never goes to a path with no realm behind it, nor to the BUBBLE route's successor by a
// slip. A realm that succeeds another (a successor registered by its predecessor's migrate) migrates on only once
// its own import has ended (R31): before page 0 nothing has moved and the lock would be stranded for good.
func NewMigrateRequest(cur realm, to string) Request {
	mustBeLive()
	return propose(cur, st.DraftMigrate(to, pkgPath, env(cur)))
}

// NewCancelRequest cancels a pending decision of this route, at once. It is proposed before Launch too.
func NewCancelRequest(cur realm, id int64) Request {
	return propose(cur, st.DraftCancel(id))
}

// Execute applies a queued decision whose 7 days have passed. Anyone may call it; the relayers do. A sweep
// payment moves coins out of the lock, so under a standing payouts flag it waits for the unpause like a claim
// (§5.9: nothing paid under a suspect verifier). A refund is never Execute's (AT2): the state refuses the kind, and
// GovDAO applies it by NewApplyRefundRequest after hlwatch's Solana check.
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
// code, page by page from 0, and receives the lock (paid to its address, with page 0) and the records to import,
// up to 500 a page (the snapshot's More says whether a page follows); a page pulled already hands over nothing.
// Page 0 moves the lock, so under a standing payouts flag it waits for the unpause like a sweep payment (R27, R16:
// nothing paid under a suspect verifier); the flag follows the claims to the successor (hlmailbox.AddRoute).
func Pull(cur realm, page int) *hlroute.Snapshot {
	if !cur.IsCurrent() {
		panic("hlgnot: that realm value is not live; pass your own cur")
	}
	path := cur.Previous().PkgPath()
	if st.MigratedTo == "" || path != st.MigratedTo {
		panic("hlgnot: only the successor named by a migrate decision pulls")
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

// Render:
//
//	""                the route's page (the first 100 waiting claims and sweep entries, the rest counted)
//	"decisions"       the decisions page: the last 100 pending and executed per kind
//	"json"            the figures for the agents
//	"decisions.json"  every decision
//	"claim/<id>"      one claim by message id, or the swept amount, or "null"
//	"claims/<from>"   up to 100 waiting claims from the <from>-th on, in the page's order, as a JSON array
//	"sweeps/<from>"   up to 100 sweep entries from the <from>-th on, by id, as a JSON array
//	"send/<id>"       one send by message id ({"id","from","amount","at","imported","refunded","writtenOff"}), or "null"
//	"refunds/<from>"  up to 100 sends refunded here from the <from>-th on, by id, as a JSON array (AQ2: what the
//	                  monitors read to drop a refunded send from what is in flight)
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
		b.WriteString("# GNOT across chains\n\n")
		b.WriteString("The bridge's GNOT route on gno.land. GNOT sent to Solana is locked here, and the synthetic GNOT there is backed by it one to one; a burn there is credited here as a claim, paid under the meters. Every setting moves only by a decision made with this realm's builders — the governor's own until it yields, a GovDAO proposal after.\n\n")
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
