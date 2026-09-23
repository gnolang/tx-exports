package home

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

// The crew roster lists everyone who built with samcrew, whether or not they
// have a gno.land identity yet.
//
// A member belongs to a team (engineering, media, ...) and starts with a
// public link, usually their GitHub profile. Once they have an on-chain
// identity, the admin runs LinkProfile: the card then links to their home
// realm (or /u/<address>), is marked ON CHAIN, and the member can write their
// own line with SetLine.

const (
	maxCrew      = 96 // each card costs render gas; keeps Render("") far below the query ceiling
	maxIDLen     = 32
	maxHandleLen = 32
	maxRoleLen   = 40
	maxLineLen   = 160
)

type member struct {
	id     string // stable key, [a-z0-9._-]
	handle string // shown on the card
	role   string
	team   string // [a-z0-9._-], groups the cards
	url    string // public link used until the member is on chain
	addr   address
	home   string // "/r/..." home realm, preferred link once set
	line   string
	order  int
	joined int64
}

var (
	crew      = avl.NewTree() // id -> *member
	byAddr    = avl.NewTree() // address string -> id, for SetLine
	nextOrder int
)

// oneLine rejects text that would break out of its markdown or SVG slot.
func oneLine(field, s string, max int) {
	if len(s) > max {
		panic(field + " too long: max " + strconv.Itoa(max) + " bytes")
	}
	if strings.ContainsAny(s, "|\n\r") {
		panic(field + " must be one line without '|'")
	}
}

func validURL(u string) bool {
	return (strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "/") && !strings.HasPrefix(u, "//")) &&
		len(u) <= 200 && !strings.ContainsAny(u, " ()<>\"|\\\n\r")
}

// mdEscape turns member-written text into plain text: every character that
// markdown could read as a link, image, emphasis, code or HTML is escaped.
func mdEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune("\\`*_[]()<>!#|~{}", r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func addMember(id, handle, role, team, url string) {
	if len(id) > maxIDLen || !validSlug(id) {
		panic("invalid member id: want 1-32 bytes of [a-z0-9._-]")
	}
	if crew.Has(id) {
		panic("already in the crew: " + id)
	}
	if crew.Size() >= maxCrew {
		panic("the roster is full: " + strconv.Itoa(maxCrew) + " members")
	}
	m := &member{id: id}
	setIdentity(m, handle, role, team, url)
	nextOrder++
	m.order = nextOrder
	m.joined = runtime.ChainHeight()
	crew.Set(id, m)
}

func setIdentity(m *member, handle, role, team, url string) {
	if handle == "" {
		panic("handle required")
	}
	oneLine("handle", handle, maxHandleLen)
	oneLine("role", role, maxRoleLen)
	if len(team) > maxIDLen || !validSlug(team) {
		panic("invalid team: want 1-32 bytes of [a-z0-9._-]")
	}
	if !validURL(url) {
		panic("link must be https:// or a /path, without spaces or markdown characters")
	}
	m.handle, m.role, m.team, m.url = handle, role, team, url
}

func mustMember(id string) *member {
	v := crew.Get(id)
	if v == nil {
		panic("not in the crew: " + id)
	}
	return v.(*member)
}

// AddMember puts someone on the roster, in a team, linked to a public page.
func AddMember(cur realm, id, handle, role, team, url string) {
	assertAdmin(cur)
	addMember(id, handle, role, team, url)
}

// UpdateMember changes a member's handle, role, team and public link.
func UpdateMember(cur realm, id, handle, role, team, url string) {
	assertAdmin(cur)
	setIdentity(mustMember(id), handle, role, team, url)
}

// LinkProfile ties a member to their gno.land identity. home is their home
// realm path ("/r/..."), or "" to link to /u/<addr>. From then on the member
// can write their own line with SetLine.
func LinkProfile(cur realm, id string, addr address, home string) {
	assertAdmin(cur)
	m := mustMember(id)
	if !addr.IsValid() {
		panic("invalid address")
	}
	if home != "" && (!strings.HasPrefix(home, "/r/") || strings.ContainsAny(home, " ()<>\"|\\\n\r")) {
		panic("home must be a /r/... path")
	}
	if other := byAddr.Get(addr.String()); other != nil && other.(string) != id {
		panic("address already linked to " + other.(string))
	}
	if m.addr != "" {
		byAddr.Remove(m.addr.String())
	}
	if m.addr != addr {
		m.line = "" // a line belongs to the address that wrote it
	}
	m.addr, m.home = addr, home
	byAddr.Set(addr.String(), id)
}

// ClearLine removes a member's line, for moderation.
func ClearLine(cur realm, id string) {
	assertAdmin(cur)
	mustMember(id).line = ""
}

// RemoveMember takes someone off the roster.
func RemoveMember(cur realm, id string) {
	assertAdmin(cur)
	m := mustMember(id)
	if m.addr != "" {
		byAddr.Remove(m.addr.String())
	}
	crew.Remove(id)
}

// SetLine lets a crew member with a linked profile write their own line. It
// renders as plain text: markdown in it is escaped.
func SetLine(cur realm, line string) {
	caller := cur.Previous().Address()
	v := byAddr.Get(caller.String())
	if v == nil {
		panic("no crew profile linked to " + caller.String())
	}
	oneLine("line", line, maxLineLen)
	mustMember(v.(string)).line = line
}

// IsMember reports whether addr is linked to a crew profile.
func IsMember(addr address) bool { return byAddr.Has(addr.String()) }

// CrewSize returns the number of members on the roster.
func CrewSize() int { return crew.Size() }

// link is where a member's card points: home realm, then on-chain profile,
// then their public link.
func (m *member) link() string {
	switch {
	case m.home != "":
		return m.home
	case m.addr != "":
		return "/u/" + m.addr.String()
	}
	return m.url
}

// teamTitles names the known teams; any other team shows its raw name.
var teamTitles = map[string]string{
	"engineering": "Engineering crew",
	"media":       "Media crew",
	"alumni":      "Alumni",
}

// teamKinds picks the poster style of a team's cards.
var teamKinds = map[string]string{
	"media":  "member-media",
	"alumni": "member-alumni",
}

// crewTable shows the roster team by team, teams in the order their first
// member joined, members in the order they joined: one poster each, then the
// lines they wrote themselves.
func crewTable() string {
	if crew.Size() == 0 {
		return "_The roster is empty._"
	}
	members := make([]*member, 0, crew.Size())
	crew.Iterate("", "", func(_ string, v any) bool {
		m := v.(*member)
		i := len(members)
		members = append(members, m)
		for i > 0 && members[i-1].order > m.order {
			members[i] = members[i-1]
			i--
		}
		members[i] = m
		return false
	})

	var teams []string
	byTeam := map[string][]*member{}
	for _, m := range members {
		if _, ok := byTeam[m.team]; !ok {
			teams = append(teams, m.team)
		}
		byTeam[m.team] = append(byTeam[m.team], m)
	}

	var b strings.Builder
	onChain := 0
	var counts []string
	for _, team := range teams {
		group := byTeam[team]
		title := teamTitles[team]
		if title == "" {
			title = team
		}
		counts = append(counts, strconv.Itoa(len(group))+" "+strings.ToLower(strings.TrimSuffix(title, " crew")))
		b.WriteString("**" + title + "**")
		if team == "alumni" {
			b.WriteString(": former crew members who built gno with us.")
		}
		b.WriteString("\n\n")
		kind := teamKinds[team]
		if kind == "" {
			kind = "member"
		}
		for i := 0; i < len(group); i += cardsPerRow {
			b.WriteString("<gno-columns>\n")
			for j := i; j < i+cardsPerRow; j++ {
				if j > i {
					b.WriteString("<gno-columns-sep />\n")
				}
				if j >= len(group) {
					continue
				}
				m := group[j]
				n := strconv.Itoa(j + 1)
				if j < 9 {
					n = "0" + n
				}
				label := strings.ToUpper(strings.TrimSuffix(title, " crew")) + " · " + n
				if m.addr != "" {
					label += " · ON CHAIN"
					onChain++
				}
				c := card{kind: kind, title: m.handle, meta: m.role, url: m.link(), label: label}
				b.WriteString("[![" + mdText(m.handle) + "](" + posterURI(c) + ")](" + c.url + ")\n")
			}
			b.WriteString("</gno-columns>\n\n")
		}
	}

	b.WriteString("*" + strconv.Itoa(len(members)) + " samurai (" + strings.Join(counts, ", ") + "), " +
		strconv.Itoa(onChain) + " on chain so far. A card links to its owner's public page until they have a gno.land profile.*")

	var lines strings.Builder
	for _, m := range members {
		if m.line != "" {
			lines.WriteString("- **[" + mdText(m.handle) + "](" + m.link() + ")**: " + mdEscape(m.line) + "\n")
		}
	}
	if lines.Len() > 0 {
		b.WriteString("\n\n**In their own words.**\n\n" + lines.String())
	}
	b.WriteString("\n*Crew members on chain write their own line with [SetLine](" + webPath + "$help&func=SetLine).*")
	return b.String()
}
