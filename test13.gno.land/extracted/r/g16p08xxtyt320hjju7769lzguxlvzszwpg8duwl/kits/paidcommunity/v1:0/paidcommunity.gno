// Package paidcommunity is a GnoForge starter kit:
// joinable community with roles, optional join fee (ugnot), posts, and on-chain stats.
package paidcommunity

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/membership/v0"
	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

var (
	cfg            membership.CommunityConfig
	roleSet        *roles.RoleSet
	members        map[string]membership.Member
	posts          []Post
	nextPost       int
	inited         bool
	joinFeeUgnot   int64 // required -send on Join when > 0
	feesCollected  int64 // total ugnot accepted as join fees
	lastPostAt     int64
	memberJoinLog  int // total successful joins including founder (founder counts as 1 at init)
)

// Post is a community message.
type Post struct {
	ID      int
	Author  string
	Body    string
	Created int64
}

func ensure() {
	if roleSet == nil {
		roleSet = roles.NewRoleSet()
	}
	if members == nil {
		members = map[string]membership.Member{}
	}
}

func nowUnix() int64 {
	return time.Now().Unix()
}

// InitAdmin bootstraps the community. Caller becomes admin + first member.
func InitAdmin(cur realm, name, description string) string {
	ensure()
	if inited {
		panic("paidcommunity: already initialized")
	}
	caller := cur.Previous().Address().String()
	cfg = membership.CommunityConfig{
		Name:            name,
		Description:     description,
		OpenJoin:        true,
		RequireApproval: false,
		MaxMembers:      0,
		ActiveCount:     0,
	}
	roleSet.Grant(caller, "admin")
	roleSet.Grant(caller, "member")
	m := membership.NewMember(caller, "admin", &cfg, nowUnix())
	m.Status = membership.StatusActive
	cfg.ActiveCount = 1
	members[caller] = m
	memberJoinLog = 1
	inited = true
	return "ok: admin=" + caller
}

// SetJoinFee sets the ugnot join fee (admin). 0 = free join.
func SetJoinFee(cur realm, feeUgnot int64) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	if feeUgnot < 0 {
		panic("paidcommunity: fee cannot be negative")
	}
	joinFeeUgnot = feeUgnot
	return "join fee set"
}

// Join adds the caller as a member. When joinFeeUgnot > 0, requires -send >= fee.
func Join(cur realm, display string) string {
	ensure()
	if !inited {
		panic("paidcommunity: call InitAdmin first")
	}
	runtime.AssertOriginCall()
	caller := cur.Previous().Address().String()
	if _, exists := members[caller]; exists {
		return "already member"
	}
	if !membership.CanJoin(&cfg, cfg.ActiveCount) {
		panic("paidcommunity: capacity full")
	}

	if joinFeeUgnot > 0 {
		sent := unsafe.OriginSend().AmountOf("ugnot")
		if sent < joinFeeUgnot {
			panic("paidcommunity: join fee underpaid")
		}
		// Coins already on realm via -send; track accounting.
		feesCollected += sent
	}

	m := membership.NewMember(caller, display, &cfg, nowUnix())
	if m.Status == membership.StatusPending {
		members[caller] = m
		return "pending approval"
	}
	if m.Status != membership.StatusActive {
		membership.Activate(&m, &cfg)
	} else {
		cfg.ActiveCount++
	}
	members[caller] = m
	roleSet.Grant(caller, "member")
	memberJoinLog++
	return "joined"
}

// Approve lets admin activate a pending member.
func Approve(cur realm, addr string) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	m, ok := members[addr]
	if !ok {
		panic("paidcommunity: unknown member")
	}
	membership.Activate(&m, &cfg)
	members[addr] = m
	roleSet.Grant(addr, "member")
	memberJoinLog++
	return "approved"
}

// SetPolicy updates join policy (admin).
func SetPolicy(cur realm, openJoin, requireApproval bool, maxMembers int) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	cfg.OpenJoin = openJoin
	cfg.RequireApproval = requireApproval
	cfg.MaxMembers = maxMembers
	return "policy updated"
}

// PostMessage publishes a post (members only).
func PostMessage(cur realm, body string) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "member")
	body = strings.TrimSpace(body)
	if body == "" {
		panic("paidcommunity: empty body")
	}
	nextPost++
	ts := nowUnix()
	p := Post{ID: nextPost, Author: caller, Body: body, Created: ts}
	posts = append(posts, p)
	lastPostAt = ts
	return "post#" + strconv.Itoa(p.ID)
}

// BanMember bans an address (admin).
func BanMember(cur realm, addr string) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	m, ok := members[addr]
	if !ok {
		panic("paidcommunity: unknown member")
	}
	membership.Ban(&m, &cfg)
	members[addr] = m
	roleSet.Revoke(addr, "member")
	return "banned"
}

// WithdrawFees sends collected join fees to admin (admin only).
func WithdrawFees(cur realm) string {
	ensure()
	runtime.AssertOriginCall()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	if feesCollected <= 0 {
		return "nothing to withdraw"
	}
	amt := feesCollected
	feesCollected = 0
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), address(caller), chain.Coins{{"ugnot", amt}})
	return "withdrawn:" + strconv.FormatInt(amt, 10)
}

// --- read-only stats (callable via vm/qeval) ---

func GetMemberCount() int {
	ensure()
	return cfg.ActiveCount
}

func GetJoinLogCount() int {
	return memberJoinLog
}

func GetFeesCollected() int64 {
	return feesCollected
}

func GetJoinFee() int64 {
	return joinFeeUgnot
}

func GetLastPostAt() int64 {
	return lastPostAt
}

func GetPostCount() int {
	return nextPost
}

func GetName() string {
	return cfg.Name
}

// Render shows community + stats for gnoweb.
func Render(_ string) string {
	ensure()
	if !inited {
		return "# Paid Community Kit\n\nNot initialized. Call `InitAdmin`.\n\n*GnoForge starter kit*"
	}
	var b strings.Builder
	b.WriteString("# " + cfg.Name + "\n\n")
	b.WriteString(cfg.Description + "\n\n")
	b.WriteString("## Live stats\n\n")
	b.WriteString("| Metric | Value |\n| --- | --- |\n")
	b.WriteString("| Active members | " + strconv.Itoa(cfg.ActiveCount) + " |\n")
	b.WriteString("| Join events | " + strconv.Itoa(memberJoinLog) + " |\n")
	b.WriteString("| Join fee (ugnot) | " + strconv.FormatInt(joinFeeUgnot, 10) + " |\n")
	b.WriteString("| Fees collected (ugnot) | " + strconv.FormatInt(feesCollected, 10) + " |\n")
	b.WriteString("| Posts | " + strconv.Itoa(nextPost) + " |\n")
	b.WriteString("| Last post (unix) | " + strconv.FormatInt(lastPostAt, 10) + " |\n\n")
	b.WriteString("## Recent posts\n\n")
	start := 0
	if len(posts) > 20 {
		start = len(posts) - 20
	}
	for i := len(posts) - 1; i >= start; i-- {
		p := posts[i]
		b.WriteString("### #" + strconv.Itoa(p.ID) + " — `" + p.Author + "` · `" + strconv.FormatInt(p.Created, 10) + "`\n\n")
		b.WriteString(p.Body + "\n\n")
	}
	if len(posts) == 0 {
		b.WriteString("_No posts yet._\n")
	}
	b.WriteString("\n---\n*Powered by GnoForge `paidcommunity`*\n")
	return b.String()
}
