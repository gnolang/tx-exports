// Package home is a personal home realm. gno.land also shows it as the
// profile page at /u/<name>, which always calls Render("") and reads its
// links against /u/<name>: every link here is absolute.
package home

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	homeTab      = "home"
	workTab      = "work"
	blogTab      = "blog"
	guestbookTab = "guestbook"

	maxTabs       = 8
	maxTabName    = 20
	maxPageBytes  = 16 * 1024 // so all pages together stay under 128 KB
	maxLineRunes  = 140
	maxBadges     = 6
	maxSlugBytes  = 60
	maxTitleRunes = 100
	pageSize      = 20
	latestPosts   = 3
	seqWidth      = 10

	errUnauthorized = "home: unauthorized"
	errMasterKey    = "home: needs the master key, not a session key"
	errOwnerOnly    = "home: owner only"
	errPendingOnly  = "home: pending owner only"
	errInvalidInput = "home: invalid input: "
	errSigned       = "home: already signed"
	errNoEntry      = "home: no such entry"
	errNoTab        = "home: no such tab"
	errNoPost       = "home: no such post"
	errTabsRequired = "home: home, blog and guestbook tabs are required"
	errUgnotOnly    = "home: send ugnot only"
)

type profileData struct {
	name    string
	tagline string
}

type badge struct {
	label string
	value string
	url   string
	row   bool // starts a new row
}

type nowLine struct {
	text   string
	height int64
}

type entry struct {
	msg    string
	height int64
	hidden bool
}

// post dates are UTC days of the block time, "2006-01-02".
type post struct {
	title     string
	body      string
	published string
	edited    string // "" until the first edit
	seq       string // key in postOrder
}

type tipStats struct {
	count int
	total int64
}

var (
	owner        address
	pendingOwner address // set by TransferOwnership, cleared by AcceptOwnership
	base         string  // "/r/<name>/home"; every generated link starts with it
	profile      profileData
	badges       []badge
	now          nowLine
	tabs         []string          // tab order: home first, guestbook last
	pages        map[string]string // markdown per tab
	waves        int               // wave count; anyone can wave again
	entries      *avl.Tree         // address -> *entry
	order        *avl.Tree         // zero-padded sequence -> address
	posts        *avl.Tree         // slug -> *post
	postOrder    *avl.Tree         // zero-padded sequence -> slug
	postSeq      int               // last post sequence; never reused
	tips         tipStats
	updated      int64 // block height of the last owner write
)

// init records the deployer as owner. Under mainnet's approval flow it runs
// as the submitter, not the approver. No AssertOriginCall: init isn't a call.
func init(cur realm) {
	owner = callerOf(cur)
	base = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
	setDefaults()
}

// setDefaults writes the initial state (content.gno holds the personal part).
func setDefaults() {
	profile = defaultProfile()
	badges = defaultBadges()
	now = nowLine{}
	pendingOwner = ""
	tabs = []string{homeTab, workTab, blogTab, guestbookTab}
	pages = map[string]string{
		homeTab:      defaultHome(),
		workTab:      defaultWork,
		blogTab:      defaultBlog,
		guestbookTab: defaultGuestbook,
	}
	waves = 0
	entries = avl.NewTree()
	order = avl.NewTree()
	posts = avl.NewTree()
	postOrder = avl.NewTree()
	postSeq = 0
	tips = tipStats{}
	updated = runtime.ChainHeight()
}

// callerOf is the account guard: a live cur and a direct call from an
// account. It must not call AssertOriginCall, which refuses every call from
// inside a named helper.
func callerOf(cur realm) address {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic(errUnauthorized)
	}
	return cur.Previous().Address()
}

// assertOwner is the owner guard.
func assertOwner(cur realm) {
	if callerOf(cur) != owner {
		panic(errOwnerOnly)
	}
}

// Owner returns the current owner.
func Owner() address {
	return owner
}

// Render shows one tab, or one post at blog/<slug>. An unknown path shows
// Home and an unknown post shows Blog. The path is only compared against
// tab names or looked up as a slug, and never written into the page.
func Render(path string) string {
	tab, query, _ := strings.Cut(path, "?")
	if slug, ok := strings.CutPrefix(tab, blogTab+"/"); ok {
		if p, ok := posts.Get(slug).(*post); ok {
			return frame("", postMD(p)) // not a tab: no tab is bold
		}
		tab = blogTab
	}
	if _, ok := pages[tab]; !ok {
		tab = homeTab
	}
	return frame(tab, expand(pages[tab], tab, parsePage(query)))
}

// frame puts the tab bar above a page and the footer below it.
func frame(tab, md string) string {
	return tabBar(tab) + "\n\n" + md + "\n\n" + footer()
}

func tabURL(t string) string {
	if t == homeTab {
		return base
	}
	return base + ":" + t
}

// tabLabel capitalizes a tab name; names are ASCII by validName.
func tabLabel(t string) string {
	return strings.ToUpper(t[:1]) + t[1:]
}

// tabBar draws every tab as a linked pill, the current one in brand green.
// The current tab is linked too, because gnoweb shows an unlinked image as
// a block and the row would break. Blog stays out until there is a post.
func tabBar(current string) string {
	parts := make([]string, 0, len(tabs))
	for _, t := range tabs {
		s := segSoft(tabLabel(t))
		switch {
		case t == current:
			s = segOn(tabLabel(t))
		case t == blogTab && posts.Size() == 0:
			continue // no posts yet
		}
		parts = append(parts, pillLink(tabLabel(t), tabURL(t), tabH, 0, s))
	}
	return strings.Join(parts, " ")
}

func footer() string {
	return "---\n\nOwner " + userLink(owner) +
		" · updated at block " + strconv.FormatInt(updated, 10) +
		" · [Source](" + base + "$source)\n"
}

// parsePage reads page=N from the query; anything invalid is page 1.
func parsePage(query string) int {
	for _, kv := range strings.Split(query, "&") {
		k, v, _ := strings.Cut(kv, "=")
		if k != "page" {
			continue
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return 1
		}
		return n
	}
	return 1
}
