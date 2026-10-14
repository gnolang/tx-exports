package hlmailbox

import (
	"chain"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlroute/v0"
)

// The guardians and the watch keys (bridge/PLAN.md §5.1, §5.3): six numbered seats — 1 to 4 the guardians (3 and 4
// the outsiders'), 5 and 6 the operator's two monitors' watch keys — each holding one gno address, and three pause
// flags per seat per route: sends (refuses the route's TransferRemote), credits (refuses its Process) and payouts
// (refuses its Claim). A function of a route is refused while any seat's flag for it stands. A seat sets and clears
// its own flags; GovDAO's unpause clears every seat's flag for the functions it names, and a seat removed or
// replaced loses its flags. A guardian's payouts flag may carry the message ids it suspects — a list, or a range of
// credits (hlroute.Range: "heights:<from>-<to>", or "since:<from>" for the verifier's credits from that height on,
// so one flag covers a flood larger than a list) — which is what unlocks GovDAO's at-once void of those claims; a
// watch key's never does.
//
// The meters (§5.4) start empty after every unpause, or removal, that clears a STANDING payouts flag: this realm
// counts those events per route (the payouts epoch) and the route realms read the count.

const (
	seatCount  = 6
	guardians  = 4
	FnSends    = "sends"
	FnCredits  = "credits"
	FnPayouts  = "payouts"
	maxFlagIDs = 256 // ids a payouts flag may name

	// The launch seats (§5.3, §11.9): PLACEHOLDERS until the four people and the two monitors have keys — seat 1
	// is Jae's cold key, the rest derived test addresses — replaced in the deployed source the launch vote reads.
	launchSeat1 = address("g1562mcsvwrd2hm3nj7and8ggexdqd3hnag20cmv")
	launchSeat2 = address("g16l5nrlrp9pd8rdld7vzylrthfusv30apeq0n6z")
	launchSeat3 = address("g1acuz6nhl9hyka2a4t9t965kmd8t355hy7ukur5")
	launchSeat4 = address("g1d6nckzj9n8udw8apwrxfg929p8zm330d664ucy")
	launchSeat5 = address("g1m8d47hlnmp77rpkamxphlx9q6jfvejt89j7hfj")
	launchSeat6 = address("g1gdudkuvqdxwfncvmualymvyufdj8u7m893czuv")
)

var (
	seats         [seatCount + 1]address // by seat number; 0 unused
	routes        avl.Tree               // pkgpath → *routeRec
	flags         avl.Tree               // flagKey(route, fn, seat) → *flag
	successors    avl.Tree               // pkgpath → the route it announced for (SymbolGNOT or SymbolBUBBLE): every realm that announced itself as a route's possible successor (R25, AQ5)
	droppedRoutes avl.Tree               // pkgpath → the predecessor whose re-point dropped it (R35): the tombstone of a successor that is a route no more, cleared if a later migrate registers it afresh
)

// The routes a successor announces for (AQ5): a migrate names only a successor announced for its own route, so a
// slip never sends the GNOT lock to a realm whose code moves BUBBLE, or the other way round.
const (
	SymbolGNOT   = "GNOT"
	SymbolBUBBLE = "BUBBLE"
)

// routeRec is one route realm's record here: its payouts epoch, its place in the chain of migrations (AQ1), the
// kind 6 that enrolled it on Solana (AR1), whether it pulled page 0 of its predecessor's migration, and the
// successors its own re-points dropped (R35).
type routeRec struct {
	epoch       int64    // bumps whenever an unpause or a removal clears a standing payouts flag
	epochAt     int64    // unix time of the last bump
	predecessor string   // the route whose migrate registered this one; "" for a launch route
	successor   string   // the route this one's migrate registered; "" until it migrated
	enrolled    int64    // the block height r/hlgov last dispatched a kind 6 enrolling this route as the token's router on Solana (NoteEnrolled); 0 if never
	enrolledAt  int64    // unix time of that dispatch
	pulled      bool     // this successor pulled page 0 of its predecessor's migration, as the predecessor's Pull noted it (NotePulled, R35): the lock moved, the migration is never re-pointed, kind 6 may enrol it
	dropped     []string // the successors this route's re-points dropped (R35): each a route no more, in nobody's chain; the line's live last realm takes a message addressed to one, once its import has ended
}

// maxChain bounds the walk along a route's predecessors (Process): a chain never cycles, since AddRoute refuses a
// path that is a route already, and a bridge sees a handful of migrations in its life.
const maxChain = 16

// flag is one seat's standing flag on one function of one route.
type flag struct {
	seat   int
	at     int64         // unix time it was set, or last re-asserted
	ids    []string      // a guardian's payouts flag: the message ids it suspects (none for the other flags) …
	ranged bool          // … or the range of credits it suspects
	rng    hlroute.Range //
}

func initSeats() {
	seats[1], seats[2], seats[3], seats[4], seats[5], seats[6] = launchSeat1, launchSeat2, launchSeat3, launchSeat4, launchSeat5, launchSeat6
}

func flagKey(route, fn string, seat int) string { return route + "|" + fn + "|" + strconv.Itoa(seat) }
func flagPrefix(route, fn string) string    { return route + "|" + fn + "|" }

func isFn(fn string) bool { return fn == FnSends || fn == FnCredits || fn == FnPayouts }

func now() int64 { return time.Now().Unix() }

// ------------------------------------------------------------- reading --

// Seat is the address in a seat (1–4 guardians, 5–6 watch keys); "" if the seat is empty.
func Seat(n int) address {
	if n < 1 || n > seatCount {
		return ""
	}
	return seats[n]
}

// SeatOf is the seat an address holds, 0 if none.
func SeatOf(a address) int {
	if a == "" {
		return 0
	}
	for i := 1; i <= seatCount; i++ {
		if seats[i] == a {
			return i
		}
	}
	return 0
}

// IsGuardianSeat is whether a seat number is a guardian's (1–4) rather than a watch key's (5–6).
func IsGuardianSeat(n int) bool { return n >= 1 && n <= guardians }

// IsRoute is whether a pkgpath is one of the route realms this mailbox keeps flags for.
func IsRoute(path string) bool { return routes.Has(path) }

// Routes lists the route realms' pkgpaths.
func Routes() []string {
	var out []string
	routes.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// DroppedRoutes lists the dropped successors' pkgpaths (R35's tombstones; Dropped names each one's predecessor):
// routes no more, whose addresses the routes still refuse as a send's recipient and sweep at a credit (AT6), as a
// registered route's — a holder may have pasted one as a deposit address while its page printed it as the lock's
// holder to be, and a claim credited to it would be paid into a realm no counter of the line holds. Bounded by the
// re-points a bridge sees in its life, as Routes is by its migrations.
func DroppedRoutes() []string {
	var out []string
	droppedRoutes.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

// Paused is what the routes ask: whether any seat's flag for fn stands on route.
func Paused(route, fn string) bool {
	found := false
	flags.Iterate(flagPrefix(route, fn), flagPrefix(route, fn)+"~", func(_ string, _ any) bool {
		found = true
		return true
	})
	return found
}

// Flagged is whether some guardian's standing payouts flag on route names this claim — by its message id, or by a
// range covering the height it was credited at (a "since" range only if the verifier credited it): the test that
// makes GovDAO's void of that claim at once (§5.3). A watch key's flag never counts.
func Flagged(route, id string, height int64, verifier bool) bool {
	id = cleanID(id)
	found := false
	flags.Iterate(flagPrefix(route, FnPayouts), flagPrefix(route, FnPayouts)+"~", func(_ string, v any) bool {
		f := v.(*flag)
		if !IsGuardianSeat(f.seat) {
			return false
		}
		if f.ranged && f.rng.Covers(height, verifier) {
			found = true
			return true
		}
		for _, x := range f.ids {
			if x == id {
				found = true
				return true
			}
		}
		return false
	})
	return found
}

// PayoutsEpoch is how many times an unpause or a removal cleared a standing payouts flag on route, and when the
// last one did: the routes empty their meters when it changes (§5.4).
func PayoutsEpoch(route string) (epoch, at int64) {
	v := routes.Get(route)
	if v == nil {
		return 0, 0
	}
	r := v.(*routeRec)
	return r.epoch, r.epochAt
}

// Flags lists the standing flags of a route as "fn seat@time[ids…]" lines.
func Flags(route string) []string {
	var out []string
	flags.Iterate(route+"|", route+"|~", func(k string, v any) bool {
		f := v.(*flag)
		fn := strings.Split(k, "|")[1]
		s := fn + " by seat " + strconv.Itoa(f.seat) + " (" + string(seats[f.seat]) + ") at " + strconv.FormatInt(f.at, 10)
		if f.ranged {
			s += " naming " + f.rng.String()
		} else if len(f.ids) > 0 {
			s += " naming " + strings.Join(f.ids, ",")
		}
		out = append(out, s)
		return false
	})
	return out
}

// ------------------------------------------------------------- flagging --

func mustBeRoute(cur realm) string {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	path := cur.Previous().PkgPath()
	if !routes.Has(path) {
		panic("hlmailbox: only a route realm, not " + path)
	}
	return path
}

// parseIDs reads what a payouts flag names: a range (hlroute.ParseRange's forms), or a comma-separated list of
// message ids, at most maxFlagIDs; "" names nothing.
func parseIDs(s string) (ids []string, rng hlroute.Range, ranged bool) {
	if strings.TrimSpace(s) == "" {
		return nil, rng, false
	}
	if r, ok := hlroute.ParseRange(s); ok {
		return nil, r, true
	}
	parts := strings.Split(s, ",")
	if len(parts) > maxFlagIDs {
		panic("hlmailbox: more than " + strconv.Itoa(maxFlagIDs) + " ids")
	}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		id := cleanID(p)
		if b, err := hex.DecodeString(id); err != nil || len(b) != 32 {
			panic("hlmailbox: not a 32-byte message id in hex: " + id)
		}
		dup := false
		for _, x := range out {
			if x == id {
				dup = true
			}
		}
		if !dup {
			out = append(out, id)
		}
	}
	return out, rng, false
}

// SetFlag sets, or re-asserts, the caller's flag on one function of a route: fn is sends, credits or payouts. ids
// is what a guardian's payouts flag suspects — a comma-separated list of message ids, or a range of credits
// ("heights:<from>-<to>" inclusive, or "since:<from>" for every credit the verifier makes from that height on) —
// "" otherwise; a re-assertion replaces it. A watch key's flag never names ids or a range.
func SetFlag(cur realm, route, fn, ids string) {
	who := caller(cur)
	seat := SeatOf(who)
	if seat == 0 {
		panic("hlmailbox: not a guardian or a watch key: " + string(who))
	}
	if !routes.Has(route) {
		panic("hlmailbox: no route " + route)
	}
	if !isFn(fn) {
		panic("hlmailbox: the function must be sends, credits or payouts, not " + fn)
	}
	list, rng, ranged := parseIDs(ids)
	if (len(list) > 0 || ranged) && (fn != FnPayouts || !IsGuardianSeat(seat)) {
		panic("hlmailbox: only a guardian's payouts flag names ids, or a range")
	}
	flags.Set(flagKey(route, fn, seat), &flag{seat: seat, at: now(), ids: list, ranged: ranged, rng: rng})
	named := strconv.Itoa(len(list))
	if ranged {
		named = rng.String()
	}
	chain.Emit("Flag", "route", route, "fn", fn, "seat", strconv.Itoa(seat), "ids", named)
}

// ClearFlag clears the caller's own flag on one function of a route. It resets no meter.
func ClearFlag(cur realm, route, fn string) {
	who := caller(cur)
	seat := SeatOf(who)
	if seat == 0 {
		panic("hlmailbox: not a guardian or a watch key: " + string(who))
	}
	if _, ok := flags.Remove(flagKey(route, fn, seat)); !ok {
		panic("hlmailbox: no such flag of yours")
	}
	chain.Emit("Unflag", "route", route, "fn", fn, "seat", strconv.Itoa(seat))
}

// ClearFlags clears every seat's flag for fn on the calling route — the void builder's andUnpause option (§5.3),
// which reopens payouts in the same closure as the void. It reports whether any flag was cleared.
func ClearFlags(cur realm, fn string) bool {
	path := mustBeRoute(cur)
	if !isFn(fn) {
		panic("hlmailbox: the function must be sends, credits or payouts, not " + fn)
	}
	n, _ := clearFns(path, []string{fn}, now())
	return n > 0
}

// VacateSeat removes the key in a seat if holder still has it, its flags with it (a payouts flag among them
// restarting the route's meters): the void builder's unpause option retires keys in the same closure as the void
// (§5.3). Only a route realm may call it. It reports whether the seat was vacated: a seat whose occupant changed
// since the proposal named it, or one emptied since, is left as it is (R17), so a replacement that landed in
// between is never undone by a removal that meant the key before it.
func VacateSeat(cur realm, seat int, holder address) bool {
	mustBeRoute(cur)
	if seat < 1 || seat > seatCount {
		panic("hlmailbox: the seat must be 1 to 6")
	}
	if seats[seat] == "" || seats[seat] != holder {
		return false
	}
	clearSeat(seat, now())
	seats[seat] = ""
	chain.Emit("SeatSet", "seat", strconv.Itoa(seat), "address", "")
	return true
}

// AddRoute registers a successor route realm (a route's migrate names it), so flags can be set on it too, and
// records the succession both ways (AQ1): the caller's `successor`, the new route's `predecessor`, which is what
// lets the successor take a message addressed to the predecessor (Process) — the burns name the predecessor until
// kind 6 enrolls the successor. The path is a deployed realm's: a sub-identity's (`host#subpath`) is refused, since
// the route powers are keyed by exact pkgpath (mustBeRoute) and such a path would hand them to a token its host
// mints for free; a path that is a route already is refused (a chain never cycles). A route that migrated already
// re-points its migration (AR2): its migrate decision names another successor while the first pulled nothing —
// the route's own state refuses once page 0 moved, and a first successor that migrated on holds the lock, so it
// is refused here too — and the first's registration is dropped with the flags copied to it, the new path taking
// its place with the flags standing on the route now.
func AddRoute(cur realm, path string) {
	from := mustBeRoute(cur)
	if !strings.HasPrefix(path, "gno.land/r/") || strings.Contains(path, "#") {
		panic("hlmailbox: a route is a realm under gno.land/r/, not " + path)
	}
	if routes.Has(path) {
		panic("hlmailbox: " + path + " is a route already")
	}
	rec := routes.Get(from).(*routeRec)
	if old := rec.successor; old != "" {
		if s := Successor(old); s != "" {
			panic("hlmailbox: " + from + " migrated to " + old + ", which migrated on to " + s + " already: the migration is under way and cannot be re-pointed")
		}
		if Pulled(old) {
			panic("hlmailbox: " + from + " migrated to " + old + ", which pulled page 0 already: the migration is under way and cannot be re-pointed")
		}
		dropRoute(from, rec, old)
	}
	rec.successor = path
	undrop(path)
	routes.Set(path, &routeRec{predecessor: from})
	n := copyFlags(from, path)
	chain.Emit("RouteAdded", "pkgpath", path, "predecessor", from, "flags", strconv.Itoa(n))
}

// dropRoute forgets a successor's registration (AR2: its predecessor re-pointed the migration before it pulled
// anything): the record and every flag standing on its path. It is a route no more — nothing addressed to its
// predecessor is its to take, no route power is its — but it is remembered (R35): on its predecessor's record and
// as a tombstone, since Solana's token may still name it the router until the next kind 6 and a burn addressed to
// it must be the line's last realm's to take, never its own. A later migrate may register it afresh (undrop).
func dropRoute(from string, rec *routeRec, path string) {
	routes.Remove(path)
	var keys []string
	flags.Iterate(path+"|", path+"|~", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})
	for _, k := range keys {
		flags.Remove(k)
	}
	rec.dropped = append(rec.dropped, path)
	droppedRoutes.Set(path, from)
	chain.Emit("RouteDropped", "pkgpath", path, "predecessor", from, "flags", strconv.Itoa(len(keys)))
}

// undrop clears a path's tombstone when a migrate registers it afresh (R35): the migration re-pointed back to it
// while the newer successor pulled nothing, or a later route of the line named it. It is then a route like any
// other, with nothing pulled.
func undrop(path string) {
	v := droppedRoutes.Get(path)
	if v == nil {
		return
	}
	by := v.(string)
	droppedRoutes.Remove(path)
	if r := routes.Get(by); r != nil {
		rec := r.(*routeRec)
		var kept []string
		for _, p := range rec.dropped {
			if p != path {
				kept = append(kept, p)
			}
		}
		rec.dropped = kept
	}
	chain.Emit("RouteUndropped", "pkgpath", path, "predecessor", by)
}

// Dropped is the predecessor whose re-point dropped the realm at path from the line (R35) — a route no more, in
// nobody's chain, that neither sends (Dispatch refuses it) nor takes (Process refuses it) — or "" for a route, a
// realm never registered, or one registered afresh since.
func Dropped(path string) string {
	v := droppedRoutes.Get(path)
	if v == nil {
		return ""
	}
	return v.(string)
}

// Pulled is whether the successor at path pulled page 0 of its predecessor's migration, as the predecessor's Pull
// noted it (NotePulled): the lock and the counters moved, so the migration is never re-pointed and a kind 6 may
// enrol it (R35). False for a launch route, a successor that pulled nothing, or no route.
func Pulled(path string) bool {
	v := routes.Get(path)
	if v == nil {
		return false
	}
	return v.(*routeRec).pulled
}

// NotePulled is the predecessor's note, from its Pull, that the successor its migrate registered has pulled page 0
// (R35): the lock and the counters moved with it, so the migration is under way — the route's own state refuses a
// re-point from here on, and AddRoute refuses one too — and r/hlgov's kind 6 may enrol the successor: before it a
// kind 6 could name a route a re-point then drops, leaving Solana's token minting for a realm in nobody's chain.
// Only the route whose successor it is notes it; a second note (a second Pull of page 0) changes nothing.
func NotePulled(cur realm, path string) {
	from := mustBeRoute(cur)
	rec := routes.Get(from).(*routeRec)
	if rec.successor != path {
		panic("hlmailbox: " + path + " is not " + from + "'s successor")
	}
	sv := routes.Get(path).(*routeRec)
	if !sv.pulled {
		sv.pulled = true
		chain.Emit("RoutePulled", "pkgpath", path, "predecessor", from)
	}
}

// copyFlags gives the route at `to` a copy of every flag standing on `from` — the seat, the time it was set, the
// ids or the range it names — keyed by the new path (R27): the pause follows the lock and the claims to the
// successor, whose Claim and Process ask their own path's flags, and clears there as any flag does — by the
// seat, by GovDAO's unpause, or with the seat's removal. It reports how many were copied.
func copyFlags(from, to string) (n int) {
	var keys []string
	var fs []*flag
	flags.Iterate(from+"|", from+"|~", func(k string, v any) bool {
		keys = append(keys, k)
		fs = append(fs, v.(*flag))
		return false
	})
	for i, k := range keys {
		f := fs[i]
		fn := strings.Split(k, "|")[1]
		flags.Set(flagKey(to, fn, f.seat), &flag{seat: f.seat, at: f.at, ids: append([]string(nil), f.ids...), ranged: f.ranged, rng: f.rng})
		n++
	}
	return n
}

// Predecessor is the route whose migrate registered path as its successor; "" for a launch route, or no route.
func Predecessor(path string) string {
	v := routes.Get(path)
	if v == nil {
		return ""
	}
	return v.(*routeRec).predecessor
}

// Successor is the route path's migrate registered; "" while it never migrated, or for no route.
func Successor(path string) string {
	v := routes.Get(path)
	if v == nil {
		return ""
	}
	return v.(*routeRec).successor
}

// Enrolled is the block height and unix time r/hlgov last dispatched a kind 6 enrolling the route at path as the
// token's router on Solana (NoteEnrolled); 0, 0 if never, or for no route. A route's refund builder waits 7 days
// after it (AR1).
func Enrolled(path string) (height, at int64) {
	v := routes.Get(path)
	if v == nil {
		return 0, 0
	}
	r := v.(*routeRec)
	return r.enrolled, r.enrolledAt
}

// mustBeHlgov is the caller check of what r/hlgov alone does here: its exact pkgpath, read from the live cur.
func mustBeHlgov(cur realm) {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	if p := cur.Previous().PkgPath(); p != hlgovPath {
		panic("hlmailbox: only " + hlgovPath + " notes an enrolment, not " + p)
	}
}

// NoteEnrolled is r/hlgov's note, from its kind-6 closure, that it dispatched a decision enrolling the route at
// path as the token's router on Solana at this block height (AR1): the route's refund builder and its apply read
// it (Enrolled) and refuse a refund until the note is 14 days old (R37: a week for the delivery, a week for
// Solana's own clock), since a refunded send stays deliverable on Solana until the predecessor's router is
// replaced and a refund that lands first lets one stranger's Reemit and delivery mint it twice. The latest note
// counts: a later kind 6 for the route restarts the wait; a cancelled one clears it (ClearEnrolled). Necessary,
// not sufficient — the realm cannot see Solana; hlwatch reads the token's enrolled router there and alarms a
// refund proposal whose successor the token has not enrolled.
func NoteEnrolled(cur realm, path string, height int64) {
	mustBeHlgov(cur)
	v := routes.Get(path)
	if v == nil {
		panic("hlmailbox: no route " + path)
	}
	if height < 1 {
		panic("hlmailbox: not a block height: " + strconv.FormatInt(height, 10))
	}
	r := v.(*routeRec)
	r.enrolled, r.enrolledAt = height, now()
	chain.Emit("RouteEnrolled", "pkgpath", path, "height", strconv.FormatInt(height, 10))
}

// ClearEnrolled is r/hlgov's word, from its cancel closure, that the kind 6 whose note stands on the route at path
// was cancelled (R37, AS2): the note goes, so the route's refund gate reads "no kind 6" again and its clock
// restarts with a re-proposal — before, a cancelled, lost or held kind 6 left the note standing and the gate
// opened on the realm's clock alone while the predecessor was still the enrolled router. r/hlgov's exact pkgpath
// alone, for a route; a route with no note is left as it is.
func ClearEnrolled(cur realm, path string) {
	mustBeHlgov(cur)
	v := routes.Get(path)
	if v == nil {
		panic("hlmailbox: no route " + path)
	}
	r := v.(*routeRec)
	if r.enrolled == 0 {
		return
	}
	r.enrolled, r.enrolledAt = 0, 0
	chain.Emit("RouteEnrolmentCleared", "pkgpath", path)
}

// successorOf is whether the route at path succeeds the route whose address, as 32 bytes, is recipient — along the
// chain of migrations, at any distance (AQ1): a burn addressed to a migrated route is taken by the successor that
// holds its lock. A successor a predecessor's re-point dropped counts as that predecessor's (R35): a burn made
// while Solana still named it the router is the line's live last realm's to take, never its own. A caller that is
// no route, or whose chain never reaches the recipient, is not.
func successorOf(path string, recipient [32]byte) bool {
	for i := 0; i < maxChain && path != ""; i++ {
		v := routes.Get(path)
		if v == nil {
			return false
		}
		path = v.(*routeRec).predecessor
		if path == "" {
			return false
		}
		if mustBytes32(chain.PackageAddress(path)) == recipient {
			return true
		}
		if pv := routes.Get(path); pv != nil {
			for _, d := range pv.(*routeRec).dropped {
				if mustBytes32(chain.PackageAddress(d)) == recipient {
					return true
				}
			}
		}
	}
	return false
}

// AnnounceSuccessor is how a realm offers itself as a route's successor (R25): called once from that realm's own
// code (its init, usually), naming the route it succeeds — GNOT or BUBBLE (AQ5: a migrate names only a successor
// announced for its own route) — it is kept under the caller's exact pkgpath, which a route's migrate builder and
// its closure require of the path they name — so the lock never goes to a path with no realm behind it (a typo,
// or an undeployed path whose namespace owner could deploy anything there and pull the lock). Only an /r/ realm,
// with its own cur: a sub-realm identity (host#subpath, a token a realm mints for free) is refused as in
// RegisterVerifier, so every entry costs a package deployment and the listing (render.gno) is bounded. Nothing is
// ever withdrawn; GovDAO reads the successor's source before it votes, as before.
func AnnounceSuccessor(cur realm, symbol string) {
	if !cur.IsCurrent() {
		panic("hlmailbox: that realm value is not live; pass your own cur")
	}
	path := cur.Previous().PkgPath()
	if !strings.HasPrefix(path, "gno.land/r/") {
		panic("hlmailbox: only a realm under gno.land/r/ announces itself as a successor, not " + path)
	}
	if cur.Previous().Subpath() != "" {
		panic("hlmailbox: a realm announces itself with its own cur, not a sub-identity (" + path + ")")
	}
	if symbol != SymbolGNOT && symbol != SymbolBUBBLE {
		panic("hlmailbox: the route a successor announces for is GNOT or BUBBLE, not " + symbol)
	}
	if successors.Has(path) {
		panic("hlmailbox: " + path + " announced itself already")
	}
	successors.Set(path, symbol)
	chain.Emit("SuccessorAnnounced", "pkgpath", path, "route", symbol)
}

// SuccessorAnnounced is whether a realm at this pkgpath announced itself as a possible successor: what a route's
// migrate builder and its closure require of the path they name (R25).
func SuccessorAnnounced(path string) bool { return successors.Has(path) }

// SuccessorFor is the route — GNOT or BUBBLE — a realm at this pkgpath announced itself as a successor of (AQ5);
// "" if it never announced itself. A route's migrate builder and its closure refuse another route's successor.
func SuccessorFor(path string) string {
	v := successors.Get(path)
	if v == nil {
		return ""
	}
	return v.(string)
}

// RouteSymbol is the token a realm's route is for (R36): the launch paths' compiled symbols; for every other
// realm the route it announced itself a successor of (SuccessorFor — a registered successor always announced,
// AQ5); "" for one that never did. r/hlgov's kind 6 compares it with the token it names, so a slip can never
// enrol one token's route as the other's router.
func RouteSymbol(path string) string {
	switch path {
	case launchRouteGNOT:
		return SymbolGNOT
	case launchRouteBUBBLE:
		return SymbolBUBBLE
	}
	return SuccessorFor(path)
}

// clearFns removes every seat's flag for the named functions on a route; payouts says whether a standing payouts
// flag went with them, in which case the route's meters restart (the epoch bumps).
func clearFns(path string, fns []string, t int64) (n int, payouts bool) {
	for _, fn := range fns {
		var keys []string
		flags.Iterate(flagPrefix(path, fn), flagPrefix(path, fn)+"~", func(k string, _ any) bool {
			keys = append(keys, k)
			return false
		})
		for _, k := range keys {
			flags.Remove(k)
			n++
			if fn == FnPayouts {
				payouts = true
			}
		}
	}
	if payouts {
		bump(path, t)
	}
	return n, payouts
}

// clearSeat removes every flag a seat holds, on every route, bumping the epoch of each route where a payouts
// flag stood.
func clearSeat(seat int, t int64) (n int) {
	suffix := "|" + strconv.Itoa(seat)
	var keys []string
	flags.Iterate("", "", func(k string, v any) bool {
		if strings.HasSuffix(k, suffix) && v.(*flag).seat == seat {
			keys = append(keys, k)
		}
		return false
	})
	for _, k := range keys {
		flags.Remove(k)
		n++
		parts := strings.Split(k, "|")
		if parts[1] == FnPayouts {
			bump(parts[0], t)
		}
	}
	return n
}

func bump(path string, t int64) {
	v := routes.Get(path)
	if v == nil {
		return
	}
	r := v.(*routeRec)
	r.epoch++
	r.epochAt = t
	chain.Emit("PayoutsReset", "route", path, "epoch", strconv.FormatInt(r.epoch, 10))
}
