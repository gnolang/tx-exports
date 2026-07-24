// Package paidcommunity is a GnoForge starter kit:
// a joinable community with roles, membership, and simple posts.
//
// Deploy under your namespace, then call InitAdmin once as deployer.
// Payment gating can be added later via Gnoswap / bank sends.
package paidcommunity

import (
	"strconv"
	"strings"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/membership/v0"
	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

var (
	cfg      membership.CommunityConfig
	roleSet  *roles.RoleSet
	members  map[string]membership.Member
	posts    []Post
	nextPost int
	inited   bool
)

// Post is a simple community message.
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

// InitAdmin bootstraps the community. Caller becomes admin.
// Only works once.
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
	m := membership.NewMember(caller, "admin", &cfg, 0)
	// Force active for founder
	m.Status = membership.StatusActive
	cfg.ActiveCount = 1
	members[caller] = m
	inited = true
	return "ok: admin=" + caller
}

// Join adds the caller as a member (open community in v0).
func Join(cur realm, display string) string {
	ensure()
	if !inited {
		panic("paidcommunity: call InitAdmin first")
	}
	caller := cur.Previous().Address().String()
	if _, exists := members[caller]; exists {
		return "already member"
	}
	if !membership.CanJoin(&cfg, cfg.ActiveCount) {
		panic("paidcommunity: capacity full")
	}
	m := membership.NewMember(caller, display, &cfg, 0)
	if m.Status == membership.StatusPending {
		members[caller] = m
		return "pending approval"
	}
	// Open join path: NewMember already Active â€” still need count via Activate-equivalent
	if m.Status != membership.StatusActive {
		membership.Activate(&m, &cfg)
	} else {
		cfg.ActiveCount++
	}
	members[caller] = m
	roleSet.Grant(caller, "member")
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
	p := Post{ID: nextPost, Author: caller, Body: body, Created: 0}
	posts = append(posts, p)
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

// Render shows community state for gnoweb.
func Render(_ string) string {
	ensure()
	if !inited {
		return "# Paid Community Kit\n\nNot initialized. Call `InitAdmin`.\n\n*GnoForge starter kit*"
	}
	var b strings.Builder
	b.WriteString("# " + cfg.Name + "\n\n")
	b.WriteString(cfg.Description + "\n\n")
	b.WriteString("**Members (active):** " + strconv.Itoa(cfg.ActiveCount) + "\n\n")
	b.WriteString("## Recent posts\n\n")
	// show last up to 20
	start := 0
	if len(posts) > 20 {
		start = len(posts) - 20
	}
	for i := len(posts) - 1; i >= start; i-- {
		p := posts[i]
		b.WriteString("### #" + strconv.Itoa(p.ID) + " â€” `" + p.Author + "`\n\n")
		b.WriteString(p.Body + "\n\n")
	}
	if len(posts) == 0 {
		b.WriteString("_No posts yet._\n")
	}
	b.WriteString("\n---\n*Powered by GnoForge `paidcommunity` kit*\n")
	return b.String()
}
