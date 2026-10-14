package hlmailbox

import (
	"chain"
	"chain/runtime"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/decisions/v0"
	"gno.land/r/gov/dao"
)

// The builders (bridge/PLAN.md §5.3): the only way a setting of this realm changes is a decision made with one of
// the New…Request functions — before the governor yields, the governor's own `maketx run` script (M1k):
//
//	hlmailbox.Govern(cross(cur), hlmailbox.NewSetVerifierRequest(cross(cur), origin, path))
//
// and after it a GovDAO proposal from a member's:
//
//	req := hlmailbox.NewSetVerifierRequest(cross(cur), origin, path)
//	dao.MustCreateProposal(cross(cur), req.Proposal())
//
// A builder takes no free text: it checks its parameters, writes them as the proposal's description, and returns
// a Request whose closure runs when the decision is made — the one closure, whether the governor runs it through
// Govern or GovDAO's proxy runs it when the proposal executes. The closure checks who decides (mustBeGovernor: the
// governor's own call until the yield, gno.land/r/gov/dao's proxy after), returns an error only when the request
// is past its 14-day deadline (GovDAO then denies the proposal for good; Govern panics with it) and panics on
// anything else (a proposal survives for a retry), gives the decision a number, and decides the at-once test
// against the live state: a removal or an unpause applies at once; a swap or an addition is queued 7 days and
// anyone applies it with Execute(id) after that. Launch is the one-shot that makes the realms live; it carries the
// same 14-day deadline (a passed launch nobody executed in 14 days lapses and is re-proposed, never a standing
// trap); before it every builder but Launch and cancel is refused.

// Request is what a builder returns (M1k): the proposal GovDAO's proxy executes after the yield (Proposal), and
// the same decision the governor runs directly before it (Govern). The closure is one; only who may run it
// changes with the yield. A Request comes from a builder alone — the type is this realm's and the closure
// unexported, so no other code can build one or change what it decides (the construction and conversion guards of
// the interrealm spec, §3.2 and §8.2) — and a stranger holding one can only hand it back to Govern, which refuses
// everyone but the governor.
type Request struct {
	proposal dao.ProposalRequest
	text     string
	decide   func(cur realm) error
}

// Proposal is the request as a GovDAO proposal: `dao.MustCreateProposal(cross(cur), req.Proposal())`.
func (r Request) Proposal() dao.ProposalRequest { return r.proposal }

// Description is the proposal's: the parameters as the builder wrote them.
func (r Request) Description() string { return r.text }

type (
	launchParams        struct{}
	setVerifierParams   struct {
		origin uint32
		path   string
	}
	rotateSignersParams struct {
		keys []Key
		rule Rule
		// A queued rotation keeps the signer set and rule it was decided against; Execute applies it only while
		// they still stand, so a removal made in between (a compromised key cut at once) can never be undone by
		// an older proposal landing on its 7th day — GovDAO proposes afresh against the set as it is.
		oldKeys []Key
		oldRule Rule
	}
	rotateSeatsParams struct {
		seats  []int
		addrs  []address               // "" removes the seat
		held   []address               // each seat's holder when the proposal was made: a removal of a seat whose occupant changed since is skipped (R21, as the void's and the unpause's, R17)
		before [seatCount + 1]address // the six seats as they stood when the proposal executed (a queued change applies only while they stand)
	}
	unpauseParams struct {
		route      string
		fns        []string
		removeSeat int
		removeAddr address // the seat's holder when the proposal was made: the seat is vacated only while it still holds it (R17)
	}
	cancelParams struct{ id int64 }
)

// who names a previous realm in a refusal: its pkgpath, or a user's address.
func who(path string, a address) string {
	if path != "" {
		return path
	}
	return string(a)
}

// mustBeGovernor is a decision's identity check (M1k), read from the closure's own live cur: until the yield the
// governor's own call — the compiled address, by its own transaction (cur.Previous() a user realm: a MsgCall's, or
// a MsgRun script's ephemeral realm, whose address is the signer's; never another realm), which is Govern's
// non-crossing call of the closure — and gno.land/r/gov/dao's proposals refused; after it, or when no governor
// was compiled, the proxy's exact pkgpath, as before M1k, and the governor refused like anyone. A refusal is a
// panic: a proposal made before the yield survives for a retry after it, within its 14 days.
func mustBeGovernor(cur realm) {
	prev := cur.Previous()
	if decisions.DAOGoverns(launchGovernor, yielded) {
		if p := prev.PkgPath(); p != decisions.DAOPath {
			panic("hlmailbox: only " + decisions.DAOPath + " executes a decision, not " + who(prev.PkgPath(), prev.Address()))
		}
		return
	}
	if !prev.IsUser() || prev.Address() != launchGovernor {
		panic("hlmailbox: until the governor yields, " + string(launchGovernor) + " alone decides, by Govern from its own key: not " + who(prev.PkgPath(), prev.Address()) + " (a GovDAO proposal is refused until the yield)")
	}
}

func mustBeLive() {
	if !live {
		panic("hlmailbox: not launched: before the Launch decision only Launch and cancel are proposed")
	}
}

// propose wraps a builder's effect in the closure every builder shares. apply runs at the decision with the time
// the request was made and the time now; it records the decision.
func propose(cur realm, kind, text string, apply func(made, t int64)) Request {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	made := now()
	cb := func(cur realm) error {
		mustBeGovernor(cur)
		t := now()
		if err := decisions.Expired(made, t); err != nil {
			return err
		}
		apply(made, t)
		return nil
	}
	return request(cur, kind, text, cb)
}

// request is a builder's Request: the proposal around the closure for GovDAO's path, the closure itself for the
// governor's.
func request(cur realm, kind, text string, cb func(cur realm) error) Request {
	return Request{proposal: dao.NewProposalRequest("hlmailbox: "+kind, text, dao.NewSimpleExecutor(0, cur, cb, text)), text: text, decide: cb}
}

// Govern is the governor's way in before the yield (M1k): the governor — the compiled launchGovernor, by its own
// transaction (a MsgCall, or the MsgRun script that makes the request in the same transaction; never through
// another realm) — makes a builder's decision directly, the same closure GovDAO's proxy runs after the yield: the
// same checks, the same at-once test, the same 7-day queue and 14-day deadline, the same record and events. The
// closure is called non-crossing, in this frame, so it reads the governor from cur.Previous() as it reads the
// proxy after the yield. Refused for anyone else, and for everyone once the governor yielded (or when none was
// compiled): GovDAO's proposals decide then. A request past its 14 days is refused (the deadline error, as a
// proposal's denial) and made afresh.
func Govern(cur realm, r Request) {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	if r.decide == nil {
		panic("hlmailbox: not a builder's request")
	}
	if decisions.DAOGoverns(launchGovernor, yielded) {
		panic("hlmailbox: " + governedBy() + ": a decision is a GovDAO proposal, never Govern")
	}
	mustBeGovernor(cur)
	if err := r.decide(cur); err != nil {
		panic("hlmailbox: " + err.Error())
	}
}

// governedBy says why Govern is closed: the yield's height, or no governor compiled.
func governedBy() string {
	if launchGovernor == "" {
		return "no governor was compiled, " + decisions.DAOPath + " governs from the first block"
	}
	return "the governor yielded at height " + strconv.FormatInt(yielded, 10) + ", " + decisions.DAOPath + " governs since"
}

// Yield is the governor's one-way hand-over to GovDAO (M1k): from this block gno.land/r/gov/dao's proposals are
// the only way a decision is made on every bridge realm — each reads Yielded here before it accepts one, so no
// realm is ever yielded apart from the rest — and Govern is closed for good. The governor alone, by its own
// transaction; refused when no governor was compiled (GovDAO governs from the first block) and a second time. A
// decision the governor queued still applies by Execute(id) after its 7 days, or GovDAO cancels it.
func Yield(cur realm) {
	caller(cur)
	if launchGovernor == "" {
		panic("hlmailbox: no governor was compiled: " + decisions.DAOPath + " governs from the first block")
	}
	if yielded != 0 {
		panic("hlmailbox: the governor yielded at height " + strconv.FormatInt(yielded, 10) + " already")
	}
	prev := cur.Previous()
	if !prev.IsUser() || prev.Address() != launchGovernor {
		panic("hlmailbox: only the governor " + string(launchGovernor) + " yields, not " + who(prev.PkgPath(), prev.Address()))
	}
	yielded = runtime.ChainHeight() // never 0: the chain's first executing block is height 1
	chain.Emit("Yielded", "governor", string(launchGovernor), "height", strconv.FormatInt(yielded, 10))
}

func queue(kind, text string, params any, made, t int64) *decisions.Decision {
	d := ledger.Record(kind, text, params, made, t, t+decisions.Delay)
	d.Note = "queued 7 days"
	chain.Emit("Decision", "id", strconv.FormatInt(d.ID, 10), "kind", kind, "state", "queued")
	return d
}

func atOnce(kind, text string, params any, made, t int64, note string) *decisions.Decision {
	d := ledger.Record(kind, text, params, made, t, t)
	ledger.Apply(d, t, "at once: "+note)
	chain.Emit("Decision", "id", strconv.FormatInt(d.ID, 10), "kind", kind, "state", "applied")
	return d
}

// ------------------------------------------------------------- launch --

// NewLaunchRequest is the launch's builder — the governor's decision like any other (M1k), the launch vote's once
// the governor has yielded: its execution makes the realms live, once, with the compiled values. It carries the
// 14-day deadline every builder carries: a passed launch nobody executed within 14 days of its proposal returns
// the deadline error (GovDAO denies it for good) and the launch is proposed again, so a forgotten vote is never a
// standing trap. A second execution errors.
func NewLaunchRequest(cur realm) Request {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	if live {
		panic("hlmailbox: launched already")
	}
	made := now()
	text := "launch: the compiled values go live — verifier " + launchVerifier + " for origin " + u32(launchOrigin) +
		", signers " + launchSigners + " under the rule " + Rule{Threshold: launchThreshold}.String() +
		", routes " + launchRouteGNOT + " and " + launchRouteBUBBLE + ", seats " + seatsText()
	cb := func(cur realm) error {
		mustBeGovernor(cur)
		t := now()
		if err := decisions.Expired(made, t); err != nil {
			return err
		}
		if live {
			return errors.New("hlmailbox: launched already")
		}
		live, launchedAt = true, t
		atOnce("launch", text, launchParams{}, made, t, "live")
		chain.Emit("Launch", "at", strconv.FormatInt(t, 10))
		return nil
	}
	return request(cur, "launch", text, cb)
}

func seatsText() string {
	parts := make([]string, 0, seatCount)
	for i := 1; i <= seatCount; i++ {
		parts = append(parts, strconv.Itoa(i)+":"+string(seats[i]))
	}
	return strings.Join(parts, ",")
}

// ------------------------------------------------------------- verifier --

// NewSetVerifierRequest activates a registered verifier for an origin, 7 days after the proposal executes.
func NewSetVerifierRequest(cur realm, origin uint32, path string) Request {
	mustBeLive()
	if origin == localDomain {
		panic("hlmailbox: this chain's own domain has no verifier")
	}
	if !verifiers.Has(path) {
		panic("hlmailbox: no verifier registered at " + path)
	}
	if ActiveVerifier(origin) == path {
		panic("hlmailbox: " + path + " is the active verifier for origin " + u32(origin) + " already")
	}
	text := "set verifier for origin " + u32(origin) + " to " + path
	return propose(cur, "set verifier", text, func(made, t int64) {
		mustBeLive()
		if !verifiers.Has(path) {
			panic("hlmailbox: no verifier registered at " + path)
		}
		queue("set verifier", text, setVerifierParams{origin, path}, made, t)
	})
}

// -------------------------------------------------------------- signers --

// parseSigners reads a signer set and its rule: keys in hex, comma separated; a threshold, or both groups (comma
// separated hex, subsets of the keys) with threshold 0.
func parseSigners(keys string, threshold int, groupA, groupB string) ([]Key, Rule) {
	ks := parseKeys(keys)
	if len(ks) == 0 {
		panic("hlmailbox: no signers")
	}
	a, b := parseKeys(groupA), parseKeys(groupB)
	if (len(a) == 0) != (len(b) == 0) {
		panic("hlmailbox: name both groups or neither")
	}
	if len(a) > 0 {
		if threshold != 0 {
			panic("hlmailbox: a two-group rule takes no threshold")
		}
		if !subset(a, ks) || !subset(b, ks) {
			panic("hlmailbox: every group member must be a signer")
		}
		for _, k := range a {
			if indexOf(b, k) >= 0 {
				panic("hlmailbox: a key in both groups: " + hx(k[:]))
			}
		}
		return ks, Rule{GroupA: a, GroupB: b}
	}
	if threshold < 1 || threshold > len(ks) {
		panic("hlmailbox: the threshold must be between 1 and the number of signers")
	}
	return ks, Rule{Threshold: threshold}
}

// pruned is the live rule with every key absent from ks dropped from both groups: what a pure removal leaves of
// the rule. A threshold is not pruned (§5.3: a 2-of-3 rule is still met by the 2 that remain after one removal);
// a group is (one of A and one of B is still met by the members that remain). Removing a partner — the only
// member of its group — leaves a group empty, which no proposal names, so that removal is never at once.
func pruned(ks []Key) Rule {
	r := Rule{Threshold: signerRule.Threshold}
	for _, k := range signerRule.GroupA {
		if indexOf(ks, k) >= 0 {
			r.GroupA = append(r.GroupA, k)
		}
	}
	for _, k := range signerRule.GroupB {
		if indexOf(ks, k) >= 0 {
			r.GroupB = append(r.GroupB, k)
		}
	}
	return r
}

// NewRotateSignersRequest sets the signer set and its rule together (§5.3): the keys in hex, comma separated, in
// the order signatures name them; a threshold, or §11.13's two groups (one of each must sign; threshold 0). It
// applies at once only as a pure removal — the new set a subset of the old, under the live rule pruned of the
// removed keys (the same threshold; the groups less the keys that leave), which the active verifier says the
// remaining set can still meet (Satisfiable, decided when the proposal executes); any other change, a lowered
// threshold among them, is queued 7 days, and a queued rotation applies only while the signer set and rule are
// still those it was decided against.
func NewRotateSignersRequest(cur realm, keys string, threshold int, groupA, groupB string) Request {
	mustBeLive()
	ks, rule := parseSigners(keys, threshold, groupA, groupB)
	if sameKeys(ks, signerKeys) && rule.equal(signerRule) {
		panic("hlmailbox: nothing changes")
	}
	// a pure removal is checked against the active verifier's Satisfiable when it is made too (K19): one that
	// would leave the rule unsatisfiable is nonsense, refused early — at execution the test is made again, and a
	// removal it fails then (another landed in between) is queued, never refused (§5.3)
	if rule.sameAs(pruned(ks)) && len(ks) < len(signerKeys) && subset(ks, signerKeys) && !satisfiable(ks) {
		panic("hlmailbox: the active verifier says the signers that remain cannot meet the rule: a removal never leaves the rule unsatisfiable")
	}
	text := "rotate signers to " + keysHex(ks) + " under the rule " + rule.String()
	return propose(cur, "rotate signers", text, func(made, t int64) {
		mustBeLive()
		p := rotateSignersParams{keys: ks, rule: rule}
		if rule.sameAs(pruned(ks)) && len(ks) < len(signerKeys) && subset(ks, signerKeys) && satisfiable(ks) {
			signerKeys, signerRule = ks, rule
			atOnce("rotate signers", text, p, made, t, "a removal the rule survives")
			chain.Emit("SignersSet", "count", strconv.Itoa(len(ks)), "rule", rule.String())
			return
		}
		p.oldKeys, p.oldRule = Signers()
		d := queue("rotate signers", text, p, made, t)
		d.Note += "; applies only while the signer set and rule stand as they do now"
	})
}

// ---------------------------------------------------------------- seats --

// parseSeatChanges reads "seat:address" pairs, comma separated; an empty address ("1:" or "1:-") vacates the seat.
func parseSeatChanges(changes string) ([]int, []address) {
	if strings.TrimSpace(changes) == "" {
		panic("hlmailbox: no changes")
	}
	var ns []int
	var as []address
	g := 0
	for _, p := range strings.Split(changes, ",") {
		i := strings.Index(p, ":")
		if i < 0 {
			panic("hlmailbox: a change is seat:address, not " + p)
		}
		n, err := strconv.Atoi(strings.TrimSpace(p[:i]))
		if err != nil || n < 1 || n > seatCount {
			panic("hlmailbox: the seat must be 1 to 6, not " + p[:i])
		}
		for _, x := range ns {
			if x == n {
				panic("hlmailbox: seat " + strconv.Itoa(n) + " named twice")
			}
		}
		a := address(strings.TrimSpace(p[i+1:]))
		if a == "-" {
			a = ""
		}
		if a != "" && !a.IsValid() {
			panic("hlmailbox: not an address: " + string(a))
		}
		if a == "" && seats[n] == "" {
			panic("hlmailbox: seat " + strconv.Itoa(n) + " is empty already")
		}
		if a != "" && seats[n] == a {
			panic("hlmailbox: seat " + strconv.Itoa(n) + " holds " + string(a) + " already")
		}
		if a != "" && SeatOf(a) != 0 {
			panic("hlmailbox: " + string(a) + " holds seat " + strconv.Itoa(SeatOf(a)) + " already")
		}
		for j, x := range as {
			if x != "" && x == a {
				panic("hlmailbox: " + string(a) + " named for seats " + strconv.Itoa(ns[j]) + " and " + strconv.Itoa(n))
			}
		}
		if IsGuardianSeat(n) {
			g++
		}
		ns = append(ns, n)
		as = append(as, a)
	}
	if g > 2 {
		panic("hlmailbox: two guardians at most per proposal")
	}
	return ns, as
}

func seatChangesText(ns []int, as []address) string {
	parts := make([]string, len(ns))
	for i, n := range ns {
		if as[i] == "" {
			parts[i] = "remove seat " + strconv.Itoa(n) + " (" + string(seats[n]) + ")"
		} else {
			parts[i] = "set seat " + strconv.Itoa(n) + " to " + string(as[i])
		}
	}
	return strings.Join(parts, ", ")
}

// NewRotateSeatsRequest replaces or vacates guardian and watch-key seats: changes is "seat:address" pairs, comma
// separated, an empty address vacating the seat; two guardians at most per proposal; a seat's current key is
// refused. Removals alone apply at once; any replacement queues the whole proposal 7 days, and a queued one
// applies only while the six seats still stand as they did when it was decided. A removed or replaced key's
// flags clear with it. A removal means the key the seat holds when the proposal is made (the description names
// it): a seat whose occupant changed by execution — a replacement landed in between — is skipped and the note says
// so (R21), the proposal spent if nothing was left to remove.
func NewRotateSeatsRequest(cur realm, changes string) Request {
	mustBeLive()
	ns, as := parseSeatChanges(changes)
	held := make([]address, len(ns))
	for i, n := range ns {
		held[i] = seats[n]
	}
	text := "rotate seats: " + seatChangesText(ns, as)
	return propose(cur, "rotate seats", text, func(made, t int64) {
		mustBeLive()
		p := rotateSeatsParams{seats: ns, addrs: as, held: held}
		removals := true
		for _, a := range as {
			if a != "" {
				removals = false
			}
		}
		if removals {
			vacated, skipped := applySeats(p, t)
			if len(vacated) == 0 {
				d := ledger.Record("rotate seats", text, p, made, t, t)
				ledger.Spend(d, "spent: nothing to remove, "+seatsNote(nil, skipped))
				chain.Emit("Decision", "id", strconv.FormatInt(d.ID, 10), "kind", "rotate seats", "state", "spent")
				return
			}
			atOnce("rotate seats", text, p, made, t, "removals: "+seatsNote(vacated, skipped))
			return
		}
		p.before = seats
		d := queue("rotate seats", text, p, made, t)
		d.Note += "; applies only while the seats stand as they do now"
	})
}

// applySeats makes a proposal's seat changes: a replacement as named; a removal only while the seat still holds the
// key the proposal was made against (R21). It reports the seats vacated and the removals skipped.
func applySeats(p rotateSeatsParams, t int64) (vacated, skipped []int) {
	for i, n := range p.seats {
		a := p.addrs[i]
		if a == "" {
			if seats[n] == "" || seats[n] != p.held[i] {
				skipped = append(skipped, n)
				continue
			}
			clearSeat(n, t)
			seats[n] = ""
			vacated = append(vacated, n)
			chain.Emit("SeatSet", "seat", strconv.Itoa(n), "address", "")
			continue
		}
		if SeatOf(a) != 0 && SeatOf(a) != n {
			panic("hlmailbox: " + string(a) + " holds seat " + strconv.Itoa(SeatOf(a)) + " now")
		}
		if seats[n] != "" {
			clearSeat(n, t)
		}
		seats[n] = a
		chain.Emit("SeatSet", "seat", strconv.Itoa(n), "address", string(a))
	}
	return vacated, skipped
}

// seatsNote says which seats a proposal vacated and which it skipped.
func seatsNote(vacated, skipped []int) string {
	var parts []string
	if len(vacated) > 0 {
		parts = append(parts, "seats "+seatList(vacated)+" vacated")
	}
	if len(skipped) > 0 {
		parts = append(parts, "seats "+seatList(skipped)+" skipped (the occupant changed since the proposal was made)")
	}
	return strings.Join(parts, ", ")
}

func seatList(ns []int) string {
	parts := make([]string, len(ns))
	for i, n := range ns {
		parts[i] = strconv.Itoa(n)
	}
	return strings.Join(parts, ",")
}

// -------------------------------------------------------------- unpause --

func parseFns(fns string) []string {
	var out []string
	for _, p := range strings.Split(fns, ",") {
		fn := strings.TrimSpace(p)
		if !isFn(fn) {
			panic("hlmailbox: the functions are sends, credits and payouts, not " + fn)
		}
		for _, x := range out {
			if x == fn {
				panic("hlmailbox: " + fn + " named twice")
			}
		}
		out = append(out, fn)
	}
	return out
}

// NewUnpauseRequest clears every seat's flag for the named functions of a route (sends, credits, payouts; comma
// separated), and may vacate one seat in the same stroke (removeSeat, 0 for none — one seat, so §5.3's cap of two
// guardians per proposal holds by construction; the void builder's unpause option, which takes a list, counts
// them). The seat's holder now is what the proposal means and is recorded with it: a seat whose occupant changed
// by execution — a replacement landed in between — is skipped, and the note says so (R17). It applies at once;
// the builder refuses one that would clear nothing now, and an executed one that finds nothing to clear is spent
// (recorded, no effect, no meter reset), never queued.
func NewUnpauseRequest(cur realm, routePath, fns string, removeSeat int) Request {
	mustBeLive()
	if !routes.Has(routePath) {
		panic("hlmailbox: no route " + routePath)
	}
	list := parseFns(fns)
	var removeAddr address
	if removeSeat != 0 {
		if removeSeat < 1 || removeSeat > seatCount {
			panic("hlmailbox: the seat must be 1 to 6")
		}
		if removeAddr = seats[removeSeat]; removeAddr == "" {
			panic("hlmailbox: seat " + strconv.Itoa(removeSeat) + " is empty")
		}
	}
	clears := false
	for _, fn := range list {
		if Paused(routePath, fn) {
			clears = true
		}
	}
	if !clears {
		panic("hlmailbox: no flag stands on " + fns + " of " + routePath + ": nothing to clear")
	}
	text := "unpause " + strings.Join(list, ",") + " on " + routePath
	if removeSeat != 0 {
		text += ", removing seat " + strconv.Itoa(removeSeat) + " (" + string(removeAddr) + ")"
	}
	return propose(cur, "unpause", text, func(made, t int64) {
		mustBeLive()
		p := unpauseParams{route: routePath, fns: list, removeSeat: removeSeat, removeAddr: removeAddr}
		n, payouts := clearFns(routePath, list, t)
		removed, skipped := false, false
		if removeSeat != 0 {
			if seats[removeSeat] == removeAddr {
				clearSeat(removeSeat, t)
				seats[removeSeat] = ""
				removed = true
				chain.Emit("SeatSet", "seat", strconv.Itoa(removeSeat), "address", "")
			} else {
				skipped = true
			}
		}
		seatNote := ""
		if removed {
			seatNote = ", seat " + strconv.Itoa(removeSeat) + " vacated"
		} else if skipped {
			seatNote = ", seat " + strconv.Itoa(removeSeat) + " skipped (its occupant changed since the proposal was made)"
		}
		if n == 0 && !removed {
			d := ledger.Record("unpause", text, p, made, t, t)
			ledger.Spend(d, "spent: nothing to clear"+seatNote)
			chain.Emit("Decision", "id", strconv.FormatInt(d.ID, 10), "kind", "unpause", "state", "spent")
			return
		}
		note := strconv.Itoa(n) + " flags cleared"
		if payouts {
			note += ", meters restart"
		}
		atOnce("unpause", text, p, made, t, note+seatNote)
	})
}

// --------------------------------------------------------------- cancel --

// NewCancelRequest cancels a queued decision of this realm, at once. It is the one builder proposed before Launch.
func NewCancelRequest(cur realm, id int64) Request {
	d := ledger.Get(id)
	if d == nil || !d.Pending() {
		panic("hlmailbox: decision " + strconv.FormatInt(id, 10) + " is not pending")
	}
	text := "cancel decision " + strconv.FormatInt(id, 10) + " (" + d.Text + ")"
	return propose(cur, "cancel", text, func(made, t int64) {
		if _, err := ledger.Cancel(id, t); err != nil {
			panic("hlmailbox: " + err.Error())
		}
		atOnce("cancel", text, cancelParams{id}, made, t, "cancelled")
	})
}

// -------------------------------------------------------------- execute --

// Execute applies a queued decision whose 7 days have passed. Anyone may call it; the relayers do. A queued
// rotation of signers or seats applies only while the set it was decided against still stands: one that finds
// the signers or the seats changed in between panics (it stays pending; GovDAO cancels it and proposes afresh).
func Execute(cur realm, id int64) {
	caller(cur)
	t := now()
	d, err := ledger.Due(id, t)
	if err != nil {
		panic("hlmailbox: " + err.Error())
	}
	note := "applied after the delay"
	switch p := d.Params.(type) {
	case setVerifierParams:
		if !verifiers.Has(p.path) {
			panic("hlmailbox: no verifier registered at " + p.path)
		}
		active.Set(domainKey(p.origin), p.path)
		chain.Emit("VerifierSet", "origin", u32(p.origin), "pkgpath", p.path)
	case rotateSignersParams:
		if !sameKeys(signerKeys, p.oldKeys) || !signerRule.equal(p.oldRule) {
			panic("hlmailbox: the signer set or rule changed since decision " + strconv.FormatInt(id, 10) + " was decided: cancel it and propose the rotation against the set as it stands")
		}
		signerKeys, signerRule = p.keys, p.rule
		chain.Emit("SignersSet", "count", strconv.Itoa(len(p.keys)), "rule", p.rule.String())
	case rotateSeatsParams:
		if p.before != seats {
			panic("hlmailbox: the seats changed since decision " + strconv.FormatInt(id, 10) + " was decided: cancel it and propose the change against the seats as they stand")
		}
		if _, skipped := applySeats(p, t); len(skipped) > 0 {
			note += "; " + seatsNote(nil, skipped)
		}
	default:
		panic("hlmailbox: decision " + strconv.FormatInt(id, 10) + " is not one that waits")
	}
	ledger.Apply(d, t, note)
	chain.Emit("Decision", "id", strconv.FormatInt(id, 10), "kind", d.Kind, "state", "applied")
}
