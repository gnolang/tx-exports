// Package pointsv2 is referral + check-in + trade/create points for gnomemepad.
//
// Trade/create awards are pad-only: allowed pad packages call OnTrade / OnCreate
// after a successful user action. EOAs cannot self-award trade points.
//
//	SetReferrer / CheckIn / AwardPoints / Leaderboard — same as v1
//	AllowPad / RevokePad — admin allowlist of pad package paths
//	OnTrade / OnCreate — called by pad via cross(cur)
//	ParamsInfo — extended for UI
package pointsv2

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	PointsReferrerBonus  int64 = 50
	PointsRefereeBonus   int64 = 25
	PointsCheckIn        int64 = 5
	CheckInIntervalH     int64 = 100
	// Trade / create (v2)
	PointsCreateBonus    int64 = 30  // creator on successful Create
	PointsBuyBase        int64 = 2   // base points per buy
	PointsSellBase       int64 = 1   // base points per sell
	PointsPerGnotBuy     int64 = 10  // extra pts per full GNOT bought (volume)
	PointsPerGnotSell    int64 = 3   // extra pts per full GNOT sold
	MaxTradePtsPerHeight int64 = 200 // per-user per-height cap (anti-spam)
	UgnotPerGnot         int64 = 1_000_000
	LeaderboardMax       int   = 50
	MaxLeaderboardReturn int   = 20
	MaxPadPathLen        int   = 200
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
	// allowedPads: package path -> true
	allowedPads avl.Tree
	// tradePtsAtHeight: "addr|height" -> int64 points already awarded that height
	tradePtsAtHeight avl.Tree
	// totalTradePts / totalCreatePts counters for ops
	totalTradePts  int64
	totalCreatePts int64
)

func Init(cur realm) {
	if inited {
		panic("pointsv2: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("pointsv2: EOA only")
	}
	admin = cur.Previous().Address()
	inited = true
	pointsByAddr = avl.Tree{}
	referrerOf = avl.Tree{}
	lastCheckIn = avl.Tree{}
	allowedPads = avl.Tree{}
	tradePtsAtHeight = avl.Tree{}
	chain.Emit("Init", "admin", admin.String())
}

func requireInit() {
	if !inited {
		panic("pointsv2: call Init first")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pointsv2: EOA only")
	}
	if cur.Previous().Address() != admin {
		panic("pointsv2: not admin")
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

// AllowPad registers a pad package path that may call OnTrade / OnCreate.
func AllowPad(cur realm, padPkg string) {
	requireAdmin(cur)
	padPkg = strings.TrimSpace(padPkg)
	if padPkg == "" || len(padPkg) > MaxPadPathLen {
		panic("pointsv2: invalid pad path")
	}
	if !strings.HasPrefix(padPkg, "gno.land/r/") {
		panic("pointsv2: pad must be gno.land/r/…")
	}
	allowedPads.Set(padPkg, true)
	chain.Emit("AllowPad", "pad", padPkg)
}

// RevokePad removes a pad from the allowlist.
func RevokePad(cur realm, padPkg string) {
	requireAdmin(cur)
	padPkg = strings.TrimSpace(padPkg)
	allowedPads.Remove(padPkg)
	chain.Emit("RevokePad", "pad", padPkg)
}

// IsPadAllowed reports whether path may award trade points.
func IsPadAllowed(padPkg string) bool {
	requireInit()
	return allowedPads.Has(strings.TrimSpace(padPkg))
}

// ListPads returns allowed pad paths, one per line.
func ListPads() string {
	requireInit()
	out := ""
	allowedPads.Iterate("", "", func(key string, _ any) bool {
		if out != "" {
			out += "\n"
		}
		out += key
		return false
	})
	return out
}

func requireAllowedPad(cur realm) string {
	requireInit()
	prev := cur.Previous()
	// Must be a realm call (pad), not EOA
	if prev.IsUserCall() {
		panic("pointsv2: pad realm only")
	}
	path := prev.PkgPath()
	if path == "" || !allowedPads.Has(path) {
		panic("pointsv2: pad not allowed")
	}
	return path
}

func heightCapKey(addr string, h int64) string {
	return addr + "|" + strconv.FormatInt(h, 10)
}

func remainingHeightCap(addr string, h int64) int64 {
	k := heightCapKey(addr, h)
	used := int64(0)
	if v := tradePtsAtHeight.Get(k); v != nil {
		used, _ = v.(int64)
	}
	left := MaxTradePtsPerHeight - used
	if left < 0 {
		return 0
	}
	return left
}

func consumeHeightCap(addr string, h, award int64) int64 {
	if award <= 0 {
		return 0
	}
	left := remainingHeightCap(addr, h)
	if left <= 0 {
		return 0
	}
	if award > left {
		award = left
	}
	k := heightCapKey(addr, h)
	used := int64(0)
	if v := tradePtsAtHeight.Get(k); v != nil {
		used, _ = v.(int64)
	}
	tradePtsAtHeight.Set(k, used+award)
	return award
}

// OnTrade awards points for a pad buy (side=0) or sell (side=1).
// volumeUgnot is the GNOT notional of the trade (sent in / received out).
// Returns points awarded (0 if capped).
func OnTrade(cur realm, trader address, launchID string, side int64, volumeUgnot int64) int64 {
	_ = requireAllowedPad(cur)
	if !trader.IsValid() {
		return 0
	}
	if volumeUgnot < 0 {
		volumeUgnot = 0
	}
	launchID = strings.TrimSpace(launchID)
	if launchID == "" {
		return 0
	}

	base := PointsBuyBase
	perG := PointsPerGnotBuy
	if side == 1 {
		base = PointsSellBase
		perG = PointsPerGnotSell
	} else if side != 0 {
		// ignore open / unknown
		return 0
	}

	gnotFull := volumeUgnot / UgnotPerGnot
	award := base + gnotFull*perG
	if award <= 0 {
		return 0
	}

	me := trader.String()
	h := runtime.ChainHeight()
	award = consumeHeightCap(me, h, award)
	if award <= 0 {
		return 0
	}
	addPts(me, award)
	totalTradePts += award
	chain.Emit("OnTrade",
		"trader", me,
		"id", launchID,
		"side", strconv.FormatInt(side, 10),
		"vol", strconv.FormatInt(volumeUgnot, 10),
		"pts", strconv.FormatInt(award, 10),
	)
	return award
}

// OnCreate awards create bonus to the launch creator (pad-only).
func OnCreate(cur realm, creator address, launchID string) int64 {
	_ = requireAllowedPad(cur)
	if !creator.IsValid() {
		return 0
	}
	launchID = strings.TrimSpace(launchID)
	if launchID == "" {
		return 0
	}
	me := creator.String()
	h := runtime.ChainHeight()
	award := consumeHeightCap(me, h, PointsCreateBonus)
	if award <= 0 {
		return 0
	}
	addPts(me, award)
	totalCreatePts += award
	chain.Emit("OnCreate", "creator", me, "id", launchID, "pts", strconv.FormatInt(award, 10))
	return award
}

// SetReferrer binds caller to a referrer once. Self-referral rejected.
func SetReferrer(cur realm, referrer address) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("pointsv2: EOA only")
	}
	if !referrer.IsValid() {
		panic("pointsv2: invalid referrer")
	}
	me := cur.Previous().Address()
	if me == referrer {
		panic("pointsv2: cannot refer self")
	}
	meS := me.String()
	if referrerOf.Has(meS) {
		panic("pointsv2: referrer already set")
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
		panic("pointsv2: EOA only")
	}
	me := cur.Previous().Address().String()
	h := runtime.ChainHeight()
	last := int64(0)
	if v := lastCheckIn.Get(me); v != nil {
		last, _ = v.(int64)
	}
	if last > 0 && h-last < CheckInIntervalH {
		panic("pointsv2: check-in too soon")
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
		panic("pointsv2: invalid to")
	}
	if amount == 0 {
		panic("pointsv2: amount zero")
	}
	addPts(to.String(), amount)
	chain.Emit("Award", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

func GetPoints(addr string) int64 {
	requireInit()
	return getPts(strings.TrimSpace(addr))
}

func GetReferrer(addr string) string {
	requireInit()
	v := referrerOf.Get(strings.TrimSpace(addr))
	if v == nil {
		return ""
	}
	s, _ := v.(string)
	return s
}

func Leaderboard(n int) string {
	requireInit()
	if n <= 0 {
		n = 10
	}
	if n > MaxLeaderboardReturn {
		n = MaxLeaderboardReturn
	}
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
		if len(rows) >= LeaderboardMax {
			return true
		}
		return false
	})
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

func UserCount() int {
	requireInit()
	return pointsByAddr.Size()
}

func PadCount() int {
	requireInit()
	return allowedPads.Size()
}

func TransferAdmin(cur realm, newAdmin address) {
	requireAdmin(cur)
	if !newAdmin.IsValid() {
		panic("pointsv2: invalid address")
	}
	old := admin
	admin = newAdmin
	chain.Emit("TransferAdmin", "from", old.String(), "to", newAdmin.String())
}

func Admin() string {
	requireInit()
	return admin.String()
}

// ParamsInfo for UI:
//
//	referrer|referee|checkIn|interval|createBonus|buyBase|sellBase|ptsPerGnotBuy|ptsPerGnotSell|maxPerHeight|tradePtsTotal|createPtsTotal|v2
func ParamsInfo() string {
	return strconv.FormatInt(PointsReferrerBonus, 10) + "|" +
		strconv.FormatInt(PointsRefereeBonus, 10) + "|" +
		strconv.FormatInt(PointsCheckIn, 10) + "|" +
		strconv.FormatInt(CheckInIntervalH, 10) + "|" +
		strconv.FormatInt(PointsCreateBonus, 10) + "|" +
		strconv.FormatInt(PointsBuyBase, 10) + "|" +
		strconv.FormatInt(PointsSellBase, 10) + "|" +
		strconv.FormatInt(PointsPerGnotBuy, 10) + "|" +
		strconv.FormatInt(PointsPerGnotSell, 10) + "|" +
		strconv.FormatInt(MaxTradePtsPerHeight, 10) + "|" +
		strconv.FormatInt(totalTradePts, 10) + "|" +
		strconv.FormatInt(totalCreatePts, 10) + "|v2"
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	if !inited {
		return "# gnomemepad pointsv2\n\n> Not initialized.\n"
	}
	out := "# gnomemepad pointsv2\n\n"
	out += "- Users: **" + strconv.Itoa(pointsByAddr.Size()) + "**\n"
	out += "- Allowed pads: **" + strconv.Itoa(allowedPads.Size()) + "**\n"
	out += "- Trade pts issued: **" + strconv.FormatInt(totalTradePts, 10) + "**\n"
	out += "- Create pts issued: **" + strconv.FormatInt(totalCreatePts, 10) + "**\n\n"
	out += "## API\n\n- SetReferrer / CheckIn\n- OnTrade / OnCreate (pad allowlist)\n- AllowPad / Leaderboard\n"
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
	allowedPads = avl.Tree{}
	tradePtsAtHeight = avl.Tree{}
	totalTradePts = 0
	totalCreatePts = 0
}
