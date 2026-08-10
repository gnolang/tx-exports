// Package points is a lightweight referral + points ledger for gnomemepad.
// Independent of pad â€” does not verify trades on-chain (testnet growth layer).
//
//	SetReferrer(referrer) â€” once per user; both get bonus points
//	CheckIn() â€” daily points (1 per CheckInInterval heights)
//	GetPoints / GetReferrer / Leaderboard
//	AwardPoints â€” admin only (manual campaigns)
package points

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	// Points grants
	PointsReferrerBonus  int64 = 50  // to referrer when someone sets them
	PointsRefereeBonus   int64 = 25  // to new user on first referrer set
	PointsCheckIn        int64 = 5
	CheckInIntervalH     int64 = 100 // ~blocks between check-ins (testnet-friendly)
	LeaderboardMax       int   = 50
	MaxLeaderboardReturn int   = 20
)

var (
	admin  address
	inited bool
	// pointsByAddr: address string -> int64
	pointsByAddr avl.Tree
	// referrerOf: address string -> referrer address string
	referrerOf avl.Tree
	// lastCheckIn: address string -> height int64
	lastCheckIn avl.Tree
	// score index for leaderboard: zero-padded score + addr -> addr (desc via reverse iterate)
	// We keep simple: rebuild top from scan on Leaderboard() for MVP size.
)

func Init(cur realm) {
	if inited {
		panic("points: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("points: EOA only")
	}
	admin = cur.Previous().Address()
	inited = true
	pointsByAddr = avl.Tree{}
	referrerOf = avl.Tree{}
	lastCheckIn = avl.Tree{}
	chain.Emit("Init", "admin", admin.String())
}

func requireInit() {
	if !inited {
		panic("points: call Init first")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("points: EOA only")
	}
	if cur.Previous().Address() != admin {
		panic("points: not admin")
	}
}

func getPts(addr string) int64 {
	v := pointsByAddr.Get(addr)
	if v == nil {
		return 0
	}
	n, ok := v.(int64)
	if !ok {
		return 0
	}
	return n
}

func addPts(addr string, delta int64) {
	if delta == 0 || addr == "" {
		return
	}
	cur := getPts(addr)
	next := cur + delta
	if next < 0 {
		next = 0
	}
	pointsByAddr.Set(addr, next)
}

// SetReferrer binds caller to a referrer once. Self-referral rejected.
func SetReferrer(cur realm, referrer address) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("points: EOA only")
	}
	if !referrer.IsValid() {
		panic("points: invalid referrer")
	}
	me := cur.Previous().Address()
	if me == referrer {
		panic("points: cannot refer self")
	}
	meS := me.String()
	if referrerOf.Has(meS) {
		panic("points: referrer already set")
	}
	refS := referrer.String()
	referrerOf.Set(meS, refS)
	addPts(refS, PointsReferrerBonus)
	addPts(meS, PointsRefereeBonus)
	chain.Emit("SetReferrer", "user", meS, "referrer", refS)
}

// CheckIn grants PointsCheckIn if enough heights passed since last check-in.
func CheckIn(cur realm) int64 {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("points: EOA only")
	}
	me := cur.Previous().Address().String()
	h := runtime.ChainHeight()
	last := int64(0)
	if v := lastCheckIn.Get(me); v != nil {
		last, _ = v.(int64)
	}
	if last > 0 && h-last < CheckInIntervalH {
		panic("points: check-in too soon")
	}
	lastCheckIn.Set(me, h)
	addPts(me, PointsCheckIn)
	chain.Emit("CheckIn", "user", me, "points", strconv.FormatInt(PointsCheckIn, 10))
	return getPts(me)
}

// AwardPoints is admin-only (campaigns / corrections).
func AwardPoints(cur realm, to address, amount int64) {
	requireAdmin(cur)
	if !to.IsValid() {
		panic("points: invalid to")
	}
	if amount == 0 {
		panic("points: amount zero")
	}
	addPts(to.String(), amount)
	chain.Emit("Award", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// GetPoints returns points for addr.
func GetPoints(addr string) int64 {
	requireInit()
	return getPts(strings.TrimSpace(addr))
}

// GetReferrer returns referrer address string or "".
func GetReferrer(addr string) string {
	requireInit()
	v := referrerOf.Get(strings.TrimSpace(addr))
	if v == nil {
		return ""
	}
	s, _ := v.(string)
	return s
}

// Leaderboard returns up to n lines "addr|points" sorted by points desc.
func Leaderboard(n int) string {
	requireInit()
	if n <= 0 {
		n = 10
	}
	if n > MaxLeaderboardReturn {
		n = MaxLeaderboardReturn
	}
	// Collect
	type row struct {
		addr string
		pts  int64
	}
	rows := make([]row, 0, LeaderboardMax)
	pointsByAddr.Iterate("", "", func(key string, value any) bool {
		pts, _ := value.(int64)
		if pts <= 0 {
			return false
		}
		rows = append(rows, row{addr: key, pts: pts})
		// soft cap collect
		if len(rows) >= LeaderboardMax {
			return true
		}
		return false
	})
	// Simple selection sort desc (small N)
	for i := 0; i < len(rows); i++ {
		best := i
		for j := i + 1; j < len(rows); j++ {
			if rows[j].pts > rows[best].pts {
				best = j
			}
		}
		rows[i], rows[best] = rows[best], rows[i]
	}
	if n > len(rows) {
		n = len(rows)
	}
	out := ""
	for i := 0; i < n; i++ {
		if out != "" {
			out += "\n"
		}
		out += rows[i].addr + "|" + strconv.FormatInt(rows[i].pts, 10)
	}
	return out
}

// UserCount returns addresses with any points.
func UserCount() int {
	requireInit()
	return pointsByAddr.Size()
}

// TransferAdmin rotates points admin.
func TransferAdmin(cur realm, newAdmin address) {
	requireAdmin(cur)
	if !newAdmin.IsValid() {
		panic("points: invalid address")
	}
	old := admin
	admin = newAdmin
	chain.Emit("TransferAdmin", "from", old.String(), "to", newAdmin.String())
}

// Admin returns admin address.
func Admin() string {
	requireInit()
	return admin.String()
}

// ParamsInfo for UI: referrerBonus|refereeBonus|checkIn|interval
func ParamsInfo() string {
	return strconv.FormatInt(PointsReferrerBonus, 10) + "|" +
		strconv.FormatInt(PointsRefereeBonus, 10) + "|" +
		strconv.FormatInt(PointsCheckIn, 10) + "|" +
		strconv.FormatInt(CheckInIntervalH, 10)
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	if !inited {
		return "# gnomemepad points\n\n> Not initialized.\n"
	}
	out := "# gnomemepad points\n\n"
	out += "- Users with points: **" + strconv.Itoa(pointsByAddr.Size()) + "**\n"
	out += "- Check-in: **" + strconv.FormatInt(PointsCheckIn, 10) + "** pts / " + strconv.FormatInt(CheckInIntervalH, 10) + " heights\n\n"
	out += "## API\n\n- SetReferrer(addr)\n- CheckIn()\n- GetPoints(addr) / Leaderboard(n)\n"
	_ = path
	return out
}

func resetForTest() {
	var zero address
	admin = zero
	inited = false
	pointsByAddr = avl.Tree{}
	referrerOf = avl.Tree{}
	lastCheckIn = avl.Tree{}
}
