// Package profile stores lightweight user profiles for gnomemepad.
// Independent of pad versions â€” upgrade this realm without redeploying markets.
//
//	SetProfile(displayName, bio, uri) â€” EOA only, per caller address
//	GetProfile(addr) â†’ name|bio|uri|updatedHeight
package profile

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	maxNameLen = 48
	maxBioLen  = 280
	maxURILen  = 200
)

// Profile is one user's public card (all fields exported for LaunchInfo-style reads).
type Profile struct {
	Name    string
	Bio     string
	URI     string
	Updated int64 // block height
}

var (
	// byAddr: address string -> *Profile
	byAddr avl.Tree
	inited bool
)

// Init is optional (no-op state). Kept for deploy symmetry with hub/pad.
func Init(cur realm) {
	if inited {
		panic("profile: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("profile: EOA only")
	}
	inited = true
	byAddr = avl.Tree{}
	chain.Emit("Init", "by", cur.Previous().Address().String())
}

func ensure() {
	// Lazy: allow SetProfile before Init for simpler UX; Init still recommended.
	if !inited {
		byAddr = avl.Tree{}
		inited = true
	}
}

func sanitizeText(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) > max {
		s = s[:max]
	}
	// Strip control chars
	out := ""
	for _, c := range s {
		if c >= 0x20 && c != 0x7f {
			out += string(c)
		}
	}
	return out
}

// SetProfile upserts the caller's profile.
func SetProfile(cur realm, name, bio, uri string) {
	if !cur.Previous().IsUserCall() {
		panic("profile: EOA only")
	}
	ensure()
	name = sanitizeText(name, maxNameLen)
	bio = sanitizeText(bio, maxBioLen)
	uri = sanitizeText(uri, maxURILen)
	if name == "" {
		panic("profile: name required")
	}
	if uri != "" && !(strings.HasPrefix(uri, "https://") || strings.HasPrefix(uri, "http://") || strings.HasPrefix(uri, "ipfs://")) {
		panic("profile: uri must be http(s) or ipfs")
	}
	addr := cur.Previous().Address()
	p := &Profile{
		Name:    name,
		Bio:     bio,
		URI:     uri,
		Updated: runtime.ChainHeight(),
	}
	byAddr.Set(addr.String(), p)
	chain.Emit("SetProfile", "addr", addr.String(), "name", name)
}

// ClearProfile removes the caller's profile.
func ClearProfile(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("profile: EOA only")
	}
	ensure()
	addr := cur.Previous().Address().String()
	if byAddr.Has(addr) {
		byAddr.Remove(addr)
		chain.Emit("ClearProfile", "addr", addr)
	}
}

// GetProfile returns pipe-delimited: name|bio|uri|updatedHeight
// Empty string if none.
func GetProfile(addr string) string {
	ensure()
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return ""
	}
	v := byAddr.Get(addr)
	if v == nil {
		return ""
	}
	p, ok := v.(*Profile)
	if !ok || p == nil {
		return ""
	}
	return p.Name + "|" + p.Bio + "|" + p.URI + "|" + strconv.FormatInt(p.Updated, 10)
}

// HasProfile reports whether addr has a profile.
func HasProfile(addr string) bool {
	ensure()
	return byAddr.Has(strings.TrimSpace(addr))
}

// ProfileCount returns number of profiles.
func ProfileCount() int {
	ensure()
	return byAddr.Size()
}

func sanitizeMD(s string) string {
	s = strings.ReplaceAll(s, "`", "'")
	s = strings.ReplaceAll(s, "<", "")
	s = strings.ReplaceAll(s, ">", "")
	return s
}

// Render home or user/{addr}
func Render(path string) string {
	path = strings.Trim(path, "/")
	ensure()
	if path == "" {
		out := "# gnomemepad profiles\n\n"
		out += "- Profiles: **" + strconv.Itoa(byAddr.Size()) + "**\n\n"
		out += "Call `SetProfile(name, bio, uri)` from your wallet.\n"
		return out
	}
	if strings.HasPrefix(path, "user/") {
		addr := strings.TrimPrefix(path, "user/")
		raw := GetProfile(addr)
		if raw == "" {
			return "> [!WARNING]\n> No profile for `" + sanitizeMD(addr) + "`\n"
		}
		parts := strings.SplitN(raw, "|", 4)
		name, bio, uri := parts[0], "", ""
		if len(parts) > 1 {
			bio = parts[1]
		}
		if len(parts) > 2 {
			uri = parts[2]
		}
		out := "# " + sanitizeMD(name) + "\n\n"
		out += "- Address: `" + sanitizeMD(addr) + "`\n"
		if bio != "" {
			out += "- Bio: " + sanitizeMD(bio) + "\n"
		}
		if uri != "" {
			out += "- URI: " + sanitizeMD(uri) + "\n"
		}
		return out
	}
	return "> [!WARNING]\n> Path not found\n"
}

func resetForTest() {
	byAddr = avl.Tree{}
	inited = false
}
