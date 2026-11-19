// Package miner is the on-chain season of GnoGame "Miner", a GPU mining
// game. The browser plays instantly and logs every action with its
// timestamp; "Collect" is a transaction that sends that log here. This realm
// replays the log with the same economy package the browser uses
// (p/…/gnogame/miner/v1), then collects at block time. The state kept here
// is canonical: the client replaces its own state with it after each
// Collect, so season values and badges can be checked by anyone.
//
// Seasons are global and consecutive: season n starts at
// start + (n-1)*28 days for everyone, and the daily event calendar depends
// on the season number. A player who joins mid-season gets the economy's
// newcomer boost; a returning player does not.
//
// Season end, to the second. A season's results are final at its end
// (seasonEnd, in ms): nothing changes an ended season afterwards.
//
//   - Projection: after every Join and Collect the realm settles a copy of
//     the farm up to min(lastClaim + monitoring window, season end) —
//     mining stops when the monitoring window runs out — and stores the
//     rounded value: what the farm's season ends at if the player does
//     nothing more. Since the window and the season end are fixed, it is
//     the exact final result unless the player collects again before the
//     end. A player who never comes back keeps it as their result.
//   - A logged line dated at or after the end of the farm's season is
//     skipped (ErrAfterSeason). A Collect whose block time is at or after
//     that end skips every line of the ended season too (ErrSeasonEnded):
//     actions must reach the chain before the season ends.
//   - The first Join or Collect after the farm's season ended rolls it
//     over: the stored projection becomes the season's result (it equals
//     settling the farm to the end, nothing could change it since), a
//     history entry {season, value, mined, badge, room} is added, and the
//     next farm starts in the current season at block time with the start
//     cards of the badge earned (Sapphire and Diamond included: the rank is
//     final at the end). Seasons the player skipped get no entry.
//
// Badges: Copper … Pearl by value threshold, Sapphire and Diamond by rank
// within the season (the rule is eco.Ladder's; season.gno keeps one ladder
// per season). Before a season ends its badges are what it would give "if
// the season ended now".
//
// Storage. A player is one small record: a few numbers and the farm as one
// compact string (eco.Encode, a few hundred bytes even for a big farm), not
// a tree of objects. A season keeps counts and a histogram of the results
// of at least Pearl, no per-player entry. Storage changes only through the
// player's own Join and Collect, so the storage deposit for a farm is paid,
// and refunded when it shrinks, by that player's own transaction: nobody
// else can close, shrink or grow another player's records.
//
// Log format: one action per line, "ts|op|args", ts in integer
// milliseconds. Ops (economy.js names):
//
//	b  buyCard       t,rgb      (rgb 0/1)
//	o  buyOffer      k
//	s  sellCard      id
//	c  overclock     id
//	C  ocMany        id;id;…    (may be empty; a-b is the ids a…b, a <= b)
//	w  rigSwap       r,t,rgb
//	r  buyRig        —
//	m  moveRoom      —
//	u  upgradeWatch  —
//
// Claims are not loggable: collecting happens only as the transaction
// itself, at block time, so the monitoring window cannot be faked.
//
// Which lines are replayed: a malformed log (bad syntax, unknown op, too
// long, a claim line, a timestamp more than MaxAhead past block time) aborts
// the whole Collect. Any other line that cannot be replayed is skipped and
// reported, and the Collect still collects at block time, so a stale log can
// never lock a player out: lines dated at or before the last Collect, out of
// order, more than MaxBackdate before block time, at or after the end of the
// farm's season, in a season that has already ended, or refused by the
// economy.
//
// The log is written by the client. The realm checks that every action is
// legal at its timestamp, not that a person made it then. Backdating gives
// no hindsight: prices, events, offers and the network are pure functions
// of the day and the season, so a whole season can be planned on day 1.
// What a script can do is play that plan perfectly, in real time or inside
// the MaxBackdate window, with the same result. Bot play is an open point
// for mainnet: it needs randomness the chain reveals over time, not a
// shorter window.
//
// Upgrade path (admin, see admin.gno): Halt stops Join and Collect for good,
// SetSuccessor names the next realm, ProposeAdmin/AcceptAdmin hand the admin
// role over. No admin function can edit player values, logs or badges.
//
// Gas and storage (filetests z1–z9, gno v1.8.0 tree fc79041, 2026-11-19).
// On chain every transaction also pays ≈ 4.4M for loading the economy
// package and 59k per store read: a daily Collect that is 23M here is ≈ 39M
// on a local chain (see tasarim-madencilik.md). Join ≈ 2.8M gas and ≈ 3.1 KB
// (the first player of a season ≈ 5.4 KB, with the season record); the daily
// Collect of an 80-card data-center farm (10 actions over 24 h) ≈ 23M gas and
// +32 bytes; the whole 80-card farm ≈ 5.6 KB; the rollover of that farm
// ≈ 9M gas (+4.2 KB for the first entrant into a season: the season record;
// ≈ +50 bytes for everyone after); storing the cutoffs of a 1000-player
// season ≈ 7M gas. Of a Collect, about 3M is decoding the farm, 3M encoding
// it and about 3M the projection (one settle step per hour of the monitoring
// window). 500 short actions ≈ 0.46G for a new farm and ≈ 0.56G on the
// 80-card farm. Each logged action costs about 1–4M (it settles the farm
// first), an ocMany line about 0.06M more per listed card, and every log
// byte about 10k to parse: clients should Collect after a few dozen actions
// at most. A ladder histogram entry (a distinct result of at least Pearl) is
// an avl node of ≈ 2 KB.
package miner

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"

	eco "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/gnogame/miner/v1"
)

const (
	// RulesVersion is reported by Season() so the client can tell which
	// rules the realm replays with. 2: strict season end, projections,
	// rank badges at the season end (no FinalizeSeason).
	RulesVersion = 2

	MaxLogLines = 500
	MaxLogBytes = 20000
	// MaxCardIDs: card ids on one C line, ranges expanded.
	MaxCardIDs = 1000
	// MaxAhead: a device clock may run a little ahead of block time. Log
	// timestamps up to this many ms after block time are accepted and
	// replayed at block time.
	MaxAhead int64 = 120000
	// MaxBackdate: log lines dated more than this many ms before block time
	// are skipped ("Too old"). 72 h covers the longest monitoring window
	// (48 h) plus slack for a player who comes back late.
	MaxBackdate int64 = 72 * 3600 * 1000

	// Messages of skipped log lines (besides the economy's own).
	ErrBeforeCollect = "Before the last Collect"
	ErrOutOfOrder    = "Out of order"
	ErrTooOld        = "Too old"
	ErrAfterSeason   = "After your season ended"
	ErrSeasonEnded   = "Season ended"

	// TopN: rows of the top results on the main page; SeasonRows: on a
	// season page.
	TopN       = 20
	SeasonRows = 100
)

var (
	admin   = address("g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06")
	start   int64    // ms of season 1 start, 0 = not started
	players avl.Tree // address string -> *player

	seasonMs = int64(eco.Net.SeasonDays) * eco.Day

	testNow int64 // tests set this (ms); 0 = block time
)

// player is one wallet's record: primitive fields and the farm as one
// compact string.
type player struct {
	farm        string // eco.Encode of the farm (as of the last Join/Collect)
	season      int    // the farm's season
	proj        int64  // projected result of that season (see the package comment)
	lastCollect int64  // block time (ms) of the last Collect, or of the Join
	collects    int
}

// farmOf decodes the player's farm. The realm wrote it, so it always
// decodes.
func farmOf(p *player) *eco.State {
	st, err := eco.Decode(p.farm)
	if err != nil {
		panic("corrupt farm record")
	}
	return st
}

func now() int64 {
	if testNow != 0 {
		return testNow
	}
	return time.Now().UnixMilli()
}

// seasonAt is the season number at t (ms), 0 before the first season.
func seasonAt(t int64) int {
	if start == 0 || t < start {
		return 0
	}
	return int((t-start)/seasonMs) + 1
}

// seasonStartOf is the start (ms) of season n >= 1.
func seasonStartOf(n int) int64 {
	return start + int64(n-1)*seasonMs
}

// seasonEndOf is the end (ms) of season n >= 1: its results are final from
// this moment on.
func seasonEndOf(n int) int64 {
	return seasonStartOf(n) + seasonMs
}

// ended: season n is over at block time t (t >= its end; no overflow for
// any n).
func ended(n int, t int64) bool {
	return n < seasonAt(t)
}

// Start opens season 1 at startMs (unix ms, not in the past). Admin only;
// it can be changed until the first season has begun.
func Start(cur realm, startMs int64) {
	onlyAdmin(cur.Previous().Address())
	notHalted()
	if start != 0 && now() >= start {
		panic("season already running")
	}
	if startMs <= 0 {
		panic("bad start time")
	}
	if startMs < now() {
		panic("start time is in the past")
	}
	start = startMs
	chain.Emit("SeasonStart", "start", strconv.FormatInt(start, 10))
}

func mustOpen(t int64) int {
	n := seasonAt(t)
	if n == 0 {
		panic("the first season has not started yet")
	}
	return n
}

// Join creates the caller's farm at block time, in the current season, and
// returns its state JSON (the economy.js save format). A player who joins
// mid-season gets the newcomer boost. For an existing player it only rolls
// an ended season over (see the package comment) and returns the state;
// actions dated before that moment can no longer be replayed.
func Join(cur realm) string {
	if !cur.Previous().IsUserCall() {
		panic("join directly from a wallet")
	}
	notHalted()
	key := cur.Previous().Address().String()
	t := now()
	n := mustOpen(t)
	defer cacheLast(n)
	if v := players.Get(key); v != nil {
		p := v.(*player)
		st := farmOf(p)
		if p.season < n {
			st = rollover(key, p, st, n, t)
			p.lastCollect = t
			out := st.JSON()
			save(p, st, true)
			return out
		}
		return st.JSON()
	}
	st := eco.NewState(t) // Last = LastClaim = Born = t
	st.Season = n
	st.SeasonStart = seasonStartOf(n)
	p := &player{lastCollect: t}
	out := st.JSON()
	save(p, st, true)
	players.Set(key, p)
	chain.Emit("Join", "player", key, "season", strconv.Itoa(n), "projection", strconv.FormatInt(p.proj, 10))
	return out
}

// action is one parsed log line.
type action struct {
	ts   int64 // replay time: the logged time, clamped to block time
	raw  int64 // the logged time
	op   byte
	x    [3]int
	ids  []int
	line int
	err  string // set: the line is skipped with this message
}

// Collect replays the caller's action log, then collects at block time.
// It returns {"applied":n,"skipped":[{"i":k,"err":"…"}],"season":…,
// "projection":…}: season is the farm's season after it, projection its
// projected season result (see the package comment). The farm itself
// (wallet, value, …) is read with State: formatting its floats here would
// cost every Collect gas for numbers the client reads anyway. A malformed log aborts the
// whole transaction (see the package comment). Every other line that
// cannot be replayed is skipped and reported with its line index i
// (0-based) and a message: an economy refusal (for example "Not enough
// BLK" after a tiny rounding difference), ErrBeforeCollect, ErrOutOfOrder,
// ErrTooOld, ErrAfterSeason (dated at or after the end of the farm's
// season) or ErrSeasonEnded (the farm's season ended before this Collect:
// the farm enters the current season at block time, after the replay).
func Collect(cur realm, log string) string {
	if !cur.Previous().IsUserCall() {
		panic("collect directly from a wallet")
	}
	notHalted()
	key := cur.Previous().Address().String()
	t := now()
	n := mustOpen(t)
	v := players.Get(key)
	if v == nil {
		panic("join first")
	}
	defer cacheLast(n)
	p := v.(*player)
	acts := parseLog(log, p.lastCollect, t)
	st := farmOf(p)

	applied := 0
	var skipped strings.Builder
	nSkipped := 0
	esc := map[string]string{} // escaped error texts (a handful of distinct ones)
	skip := func(line int, msg string) {
		e, ok := esc[msg]
		if !ok {
			e = jsonStr(msg)
			esc[msg] = e
		}
		if nSkipped > 0 {
			skipped.WriteByte(',')
		}
		skipped.WriteString(`{"i":`)
		skipped.WriteString(strconv.Itoa(line))
		skipped.WriteString(`,"err":`)
		skipped.WriteString(e)
		skipped.WriteByte('}')
		nSkipped++
	}
	end := seasonEndOf(p.season)
	over := t >= end // the farm's season has ended: nothing changes it now
	for _, a := range acts {
		switch {
		case a.err != "":
			skip(a.line, a.err)
		case a.raw >= end:
			skip(a.line, ErrAfterSeason)
		case over:
			skip(a.line, ErrSeasonEnded)
		default:
			if err := apply(st, a); err != nil {
				skip(a.line, err.Error())
				continue
			}
			applied++
		}
	}
	if over {
		st = rollover(key, p, st, n, t)
	}
	st.Claim(t)
	p.lastCollect = t
	p.collects++

	season := strconv.Itoa(st.Season)
	save(p, st, over)
	proj := strconv.FormatInt(p.proj, 10)
	nApplied := strconv.Itoa(applied)
	chain.Emit("Collect",
		"player", key,
		"season", season,
		"applied", nApplied,
		"skipped", strconv.Itoa(nSkipped),
		"projection", proj)
	return `{"applied":` + nApplied + `,"skipped":[` + skipped.String() + `],"season":` + season +
		`,"projection":` + proj + `}`
}

func apply(st *eco.State, a action) error {
	var err error
	switch a.op {
	case 'b':
		_, err = st.BuyCard(a.x[0], a.ts, a.x[1] == 1)
	case 'o':
		_, err = st.BuyOffer(a.x[0], a.ts)
	case 's':
		_, err = st.SellCard(a.x[0], a.ts)
	case 'c':
		_, err = st.Overclock(a.x[0], a.ts)
	case 'C':
		_, err = st.OCMany(a.ids, a.ts)
	case 'w':
		_, err = st.RigSwap(a.x[0], a.x[1], a.ts, a.x[2] == 1)
	case 'r':
		_, err = st.BuyRig(a.ts)
	case 'm':
		_, err = st.MoveRoom(a.ts)
	case 'u':
		_, err = st.UpgradeWatch(a.ts)
	}
	return err
}

// parseLog checks the whole log before anything is applied, in one pass
// over its bytes (every byte touched costs gas). after: the previous
// Collect (or Join) time; t: block time. Timestamps up to MaxAhead past
// block time are clamped to block time (a.raw keeps the logged one). A
// line is marked skipped (a.err) when its timestamp is not after `after`,
// more than MaxBackdate before t, or before an earlier replayed line; it is
// still checked for syntax. One trailing newline is allowed.
func parseLog(log string, after, t int64) []action {
	n := len(log)
	if n == 0 {
		return nil
	}
	if n > MaxLogBytes {
		panic("log too long: at most " + strconv.Itoa(MaxLogBytes) + " bytes, Collect more often")
	}
	out := []action{}
	prev := after
	i := 0
	for line := 0; i < n; line++ {
		if line >= MaxLogLines {
			panic("log too long: at most " + strconv.Itoa(MaxLogLines) + " actions, Collect more often")
		}
		// ts
		var ts int64
		j := i
		for i < n {
			c := log[i]
			if c < '0' || c > '9' {
				break
			}
			ts = ts*10 + int64(c-'0')
			i++
		}
		if i == n || log[i] == '\n' {
			bad(line, "want ts|op|args")
		}
		if i == j || i-j > 15 || log[i] != '|' {
			bad(line, "timestamp must be an integer (ms)")
		}
		if ts > t+MaxAhead {
			bad(line, "timestamp is in the future")
		}
		raw := ts
		if ts > t {
			ts = t
		}
		a := action{ts: ts, raw: raw, line: line}
		switch {
		case ts <= after:
			a.err = ErrBeforeCollect
		case ts < t-MaxBackdate:
			a.err = ErrTooOld
		case ts < prev:
			a.err = ErrOutOfOrder
		default:
			prev = ts
		}
		// op
		i++
		if i+1 >= n || log[i] == '\n' {
			bad(line, "want ts|op|args")
		}
		a.op = log[i]
		i++
		if log[i] != '|' {
			bad(line, "unknown op")
		}
		i++
		// args, up to the end of the line
		switch a.op {
		case 'b', 'w', 'o', 's', 'c':
			k := 1
			if a.op == 'b' {
				k = 2
			} else if a.op == 'w' {
				k = 3
			}
			for m := 0; m < k; m++ {
				v, end := readUint(log, i, n)
				if end == i {
					bad(line, "arguments must be integers")
				}
				a.x[m] = v
				i = end
				last := m == k-1
				if i < n && log[i] == ',' && !last {
					i++
					continue
				}
				if (i == n || log[i] == '\n') && last {
					break
				}
				if i < n && log[i] != ',' && log[i] != '\n' {
					bad(line, "arguments must be integers")
				}
				bad(line, "want "+strconv.Itoa(k)+" comma separated integers")
			}
			if a.op == 'b' && a.x[1] > 1 || a.op == 'w' && a.x[2] > 1 {
				bad(line, "rgb must be 0 or 1")
			}
		case 'C':
			// The longest lines: the digits are read here, not by
			// readUint (a call per id costs gas).
			a.ids = []int{}
			for i < n {
				c := log[i]
				if c == '\n' {
					break
				}
				v, j := 0, i
				for c >= '0' && c <= '9' {
					v = v*10 + int(c-'0')
					i++
					if i == n {
						break
					}
					c = log[i]
				}
				if i == j || i-j > 9 {
					bad(line, "card ids must be integers")
				}
				if c == '-' && i < n { // a range v-w: v, v+1, …, w
					i++
					if i == n {
						bad(line, "card ids must be integers")
					}
					c = log[i]
					w := 0
					j = i
					for c >= '0' && c <= '9' {
						w = w*10 + int(c-'0')
						i++
						if i == n {
							break
						}
						c = log[i]
					}
					if i == j || i-j > 9 {
						bad(line, "card ids must be integers")
					}
					if w < v {
						bad(line, "a card id range must ascend")
					}
					if len(a.ids)+w-v >= MaxCardIDs {
						bad(line, "too many card ids: at most "+strconv.Itoa(MaxCardIDs))
					}
					for ; v <= w; v++ {
						a.ids = append(a.ids, v)
					}
				} else {
					if len(a.ids) >= MaxCardIDs {
						bad(line, "too many card ids: at most "+strconv.Itoa(MaxCardIDs))
					}
					a.ids = append(a.ids, v)
				}
				if i == n || c == '\n' {
					break
				}
				if c != ';' {
					bad(line, "card ids must be integers")
				}
				i++
				if i == n || log[i] == '\n' {
					bad(line, "card ids must be integers")
				}
			}
		case 'r', 'm', 'u':
			if i < n && log[i] != '\n' {
				bad(line, "this op takes no arguments")
			}
		case 'K':
			bad(line, "claims cannot be logged: the Collect transaction itself collects at block time")
		default:
			bad(line, "unknown op")
		}
		out = append(out, a)
		i++ // the newline (or past the end)
	}
	return out
}

func bad(line int, why string) {
	panic("log entry " + strconv.Itoa(line) + ": " + why)
}

// readUint reads up to 9 decimal digits from s at i; n = len(s) (a len
// call per byte costs gas). end == i: no digit.
func readUint(s string, i, n int) (v, end int) {
	end = i
	for end < n && end-i < 10 {
		c := s[end]
		if c < '0' || c > '9' {
			break
		}
		v = v*10 + int(c-'0')
		end++
	}
	if end-i > 9 {
		return 0, i // too long: reported as not an integer
	}
	return v, end
}


// State returns the player's state JSON (the economy.js save format, as of
// the last Join or Collect), or "" for an address that has not joined.
func State(addr address) string {
	v := players.Get(addr.String())
	if v == nil {
		return ""
	}
	return farmOf(v.(*player)).JSON()
}

// Season returns the season clock as JSON:
// {"start","season","seasonStart","seasonEnd","day","players","rules",
// "halted","haltReason","successor"}. Times are unix ms; day is the
// current season day 1..28; seasonEnd is the second at which the current
// season's results become final. Before the first season, season,
// seasonStart, seasonEnd and day are 0. players: every address that has
// joined. halted: Join and Collect are stopped for good (see Halt);
// successor: the package path of the next realm, "" if none.
func Season() string {
	t := now()
	n := seasonAt(t)
	var ss, se int64
	day := 0
	if n > 0 {
		ss = seasonStartOf(n)
		se = ss + seasonMs
		day = int((t-ss)/eco.Day) + 1
	}
	return `{"start":` + strconv.FormatInt(start, 10) +
		`,"season":` + strconv.Itoa(n) +
		`,"seasonStart":` + strconv.FormatInt(ss, 10) +
		`,"seasonEnd":` + strconv.FormatInt(se, 10) +
		`,"day":` + strconv.Itoa(day) +
		`,"players":` + strconv.Itoa(players.Size()) +
		`,"rules":` + strconv.Itoa(RulesVersion) +
		`,"halted":` + strconv.FormatBool(halted) +
		`,"haltReason":` + jsonStr(haltReason) +
		`,"successor":` + jsonStr(successor) + `}`
}

func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			const hexd = "0123456789abcdef"
			b.WriteString(`\u00`)
			b.WriteByte(hexd[c>>4])
			b.WriteByte(hexd[c&15])
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
