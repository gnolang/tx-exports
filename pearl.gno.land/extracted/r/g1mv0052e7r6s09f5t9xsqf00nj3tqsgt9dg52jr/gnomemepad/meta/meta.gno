// Package meta stores off-pad token presentation data (description, image, socials).
// Independent of pad versions â€” upgrade without redeploying markets.
//
// Key = padPkg + "|" + launchId
// First SetMeta caller becomes owner; only owner may update later.
package meta

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	maxDescLen    = 500
	maxURILen     = 200
	maxHandleLen  = 64
	maxPadPathLen = 200
	maxLaunchId   = 32
)

// TokenMeta is presentation data for one launch (not trading state).
type TokenMeta struct {
	PadPkg      string
	LaunchID    string
	Owner       address
	Description string
	ImageURI    string
	Website     string
	Twitter     string
	Telegram    string
	Updated     int64
}

var (
	// byKey: pad|id -> *TokenMeta
	byKey  avl.Tree
	inited bool
)

func Init(cur realm) {
	if inited {
		panic("meta: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("meta: EOA only")
	}
	inited = true
	byKey = avl.Tree{}
	chain.Emit("Init", "by", cur.Previous().Address().String())
}

func ensure() {
	if !inited {
		byKey = avl.Tree{}
		inited = true
	}
}

func makeKey(padPkg, launchID string) string {
	return padPkg + "|" + launchID
}

func sanitizeText(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) > max {
		s = s[:max]
	}
	out := ""
	for _, c := range s {
		if c >= 0x20 && c != 0x7f {
			out += string(c)
		}
	}
	return out
}

func validateURI(uri string) {
	if uri == "" {
		return
	}
	if !(strings.HasPrefix(uri, "https://") || strings.HasPrefix(uri, "http://") || strings.HasPrefix(uri, "ipfs://")) {
		panic("meta: uri must be http(s) or ipfs")
	}
}

func validatePadPkg(padPkg string) {
	padPkg = strings.TrimSpace(padPkg)
	if padPkg == "" || len(padPkg) > maxPadPathLen {
		panic("meta: invalid pad path")
	}
	if !strings.HasPrefix(padPkg, "gno.land/r/") {
		panic("meta: pad must be gno.land/r/â€¦")
	}
}

// SetMeta upserts metadata for a launch. First writer owns the entry.
func SetMeta(cur realm, padPkg, launchID, description, imageURI, website, twitter, telegram string) {
	if !cur.Previous().IsUserCall() {
		panic("meta: EOA only")
	}
	ensure()
	validatePadPkg(padPkg)
	launchID = sanitizeText(launchID, maxLaunchId)
	if launchID == "" {
		panic("meta: launch id required")
	}
	description = sanitizeText(description, maxDescLen)
	imageURI = sanitizeText(imageURI, maxURILen)
	website = sanitizeText(website, maxURILen)
	twitter = sanitizeText(twitter, maxHandleLen)
	telegram = sanitizeText(telegram, maxHandleLen)
	validateURI(imageURI)
	validateURI(website)

	key := makeKey(padPkg, launchID)
	caller := cur.Previous().Address()
	existing := byKey.Get(key)
	if existing != nil {
		tm := existing.(*TokenMeta)
		if tm.Owner != caller {
			panic("meta: not owner")
		}
		tm.Description = description
		tm.ImageURI = imageURI
		tm.Website = website
		tm.Twitter = twitter
		tm.Telegram = telegram
		tm.Updated = runtime.ChainHeight()
		byKey.Set(key, tm)
	} else {
		tm := &TokenMeta{
			PadPkg:      padPkg,
			LaunchID:    launchID,
			Owner:       caller,
			Description: description,
			ImageURI:    imageURI,
			Website:     website,
			Twitter:     twitter,
			Telegram:    telegram,
			Updated:     runtime.ChainHeight(),
		}
		byKey.Set(key, tm)
	}
	chain.Emit("SetMeta", "key", key, "owner", caller.String())
}

// GetMeta returns:
//
//	owner|description|imageURI|website|twitter|telegram|updated
//
// Empty string if none.
func GetMeta(padPkg, launchID string) string {
	ensure()
	key := makeKey(strings.TrimSpace(padPkg), strings.TrimSpace(launchID))
	v := byKey.Get(key)
	if v == nil {
		return ""
	}
	tm := v.(*TokenMeta)
	return tm.Owner.String() + "|" +
		tm.Description + "|" +
		tm.ImageURI + "|" +
		tm.Website + "|" +
		tm.Twitter + "|" +
		tm.Telegram + "|" +
		strconv.FormatInt(tm.Updated, 10)
}

// HasMeta reports whether metadata exists.
func HasMeta(padPkg, launchID string) bool {
	ensure()
	return byKey.Has(makeKey(strings.TrimSpace(padPkg), strings.TrimSpace(launchID)))
}

// MetaCount returns number of entries.
func MetaCount() int {
	ensure()
	return byKey.Size()
}

// ClearMeta removes caller's owned entry.
func ClearMeta(cur realm, padPkg, launchID string) {
	if !cur.Previous().IsUserCall() {
		panic("meta: EOA only")
	}
	ensure()
	key := makeKey(strings.TrimSpace(padPkg), strings.TrimSpace(launchID))
	v := byKey.Get(key)
	if v == nil {
		return
	}
	tm := v.(*TokenMeta)
	if tm.Owner != cur.Previous().Address() {
		panic("meta: not owner")
	}
	byKey.Remove(key)
	chain.Emit("ClearMeta", "key", key)
}

func sanitizeMD(s string) string {
	s = strings.ReplaceAll(s, "`", "'")
	s = strings.ReplaceAll(s, "<", "")
	s = strings.ReplaceAll(s, ">", "")
	return s
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	ensure()
	if path == "" {
		return "# gnomemepad meta\n\n- Entries: **" + strconv.Itoa(byKey.Size()) + "**\n\n" +
			"SetMeta(padPkg, launchID, description, imageURI, website, twitter, telegram)\n"
	}
	return "> [!WARNING]\n> Path not found: " + sanitizeMD(path) + "\n"
}

func resetForTest() {
	byKey = avl.Tree{}
	inited = false
}
