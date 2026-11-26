// Package tokeninfo is an on-chain registry of token profiles: a description,
// a logo and official links for any GRC20 token listed in grc20reg.
//
// Only the people behind a token can write its profile:
//
//   - the owner of the namespace the token was deployed under, that is the
//     address in gno.land/r/g1.../ or the current owner of the registered
//     name in gno.land/r/<name>/ (see r/sys/users);
//   - the token's own realm, calling from its code;
//   - editors the owner (or the token realm) has added.
//
// Explorers, wallets and other realms read profiles with Get or Fields, so a
// project fills in its links once and every app shows the same verified data.
package tokeninfo

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

// Roles say why a caller may edit a profile.
const (
	RoleOwner  = "owner"  // owns the token's namespace
	RoleRealm  = "realm"  // the token's own realm
	RoleEditor = "editor" // added by the owner or the realm
)

// Profile is what a token publishes about itself. Every field is optional.
type Profile struct {
	Token       string // token path, e.g. gno.land/r/gnoswap/gns.GNS
	Description string
	Website     string // https URL
	Logo        string // https URL of an image
	X           string // handle, without @
	Telegram    string // handle, without @
	Discord     string // https://discord.gg/... invite
	GitHub      string // owner or owner/repo
	UpdatedBy   address
	UpdatedAt   int64  // block height
	Role        string // RoleOwner, RoleRealm or RoleEditor
}

var (
	profiles = avl.NewTree() // token path -> *Profile
	editors  = avl.NewTree() // token path -> *avl.Tree (address -> true)
	hidden   = avl.NewTree() // token path -> reason (string)

	// admin can only hide and unhide profiles; it can never write one. The
	// deployer (set in init) until it calls TransferAdmin.
	admin address
)

// SetProfile creates or replaces the whole profile of token. Empty fields are
// cleared. The caller must be the namespace owner, the token realm or an editor.
func SetProfile(cur realm, token, description, website, logo, x, telegram, discord, github string) {
	who, role := authorize(cur, token)
	p := &Profile{
		Token:       token,
		Description: mustDescription(description),
		Website:     mustURL("website", website),
		Logo:        mustURL("logo", logo),
		X:           mustHandle("x", x, 1, 15, false),
		Telegram:    mustHandle("telegram", telegram, 5, 32, false),
		Discord:     mustDiscord(discord),
		GitHub:      mustGitHub(github),
		UpdatedBy:   who,
		UpdatedAt:   runtime.ChainHeight(),
		Role:        role,
	}
	profiles.Set(token, p)
	chain.Emit("ProfileSet", "token", token, "by", who.String(), "role", role)
}

// ClearProfile deletes the profile of token. Editors stay.
func ClearProfile(cur realm, token string) {
	who, role := authorize(cur, token)
	if _, removed := profiles.Remove(token); !removed {
		panic("tokeninfo: " + token + " has no profile")
	}
	chain.Emit("ProfileCleared", "token", token, "by", who.String(), "role", role)
}

// AddEditor lets editor write the profile of token. Only the namespace owner
// or the token realm can add editors.
func AddEditor(cur realm, token string, editor address) {
	who, role := authorize(cur, token)
	if role == RoleEditor {
		panic("tokeninfo: editors cannot add editors")
	}
	if !editor.IsValid() {
		panic("tokeninfo: invalid editor address")
	}
	set := editors.Get(token)
	if set == nil {
		set = avl.NewTree()
		editors.Set(token, set)
	}
	if set.(*avl.Tree).Size() >= maxEditors {
		panic("tokeninfo: too many editors")
	}
	set.(*avl.Tree).Set(editor.String(), true)
	chain.Emit("EditorAdded", "token", token, "editor", editor.String(), "by", who.String())
}

// RemoveEditor revokes editor. The owner and the token realm can remove anyone;
// an editor can remove only itself.
func RemoveEditor(cur realm, token string, editor address) {
	who, role := authorize(cur, token)
	if role == RoleEditor && who != editor {
		panic("tokeninfo: editors can only remove themselves")
	}
	set := editors.Get(token)
	if set == nil {
		panic("tokeninfo: not an editor")
	}
	if _, removed := set.(*avl.Tree).Remove(editor.String()); !removed {
		panic("tokeninfo: not an editor")
	}
	if set.(*avl.Tree).Size() == 0 {
		editors.Remove(token)
	}
	chain.Emit("EditorRemoved", "token", token, "editor", editor.String(), "by", who.String())
}

// Hide takes a profile out of Get, Fields and Render, for abuse such as a
// phishing link. The reason is public. Admin only.
func Hide(cur realm, token, reason string) {
	assertAdmin(cur)
	if !profiles.Has(token) {
		panic("tokeninfo: " + token + " has no profile")
	}
	reason = mustText("reason", reason, maxReason)
	if reason == "" {
		panic("tokeninfo: a reason is required")
	}
	hidden.Set(token, reason)
	chain.Emit("ProfileHidden", "token", token, "reason", reason)
}

// Unhide shows a hidden profile again. Admin only.
func Unhide(cur realm, token string) {
	assertAdmin(cur)
	if _, removed := hidden.Remove(token); !removed {
		panic("tokeninfo: " + token + " is not hidden")
	}
	chain.Emit("ProfileUnhidden", "token", token)
}

// TransferAdmin hands moderation to another address. Admin only.
func TransferAdmin(cur realm, next address) {
	assertAdmin(cur)
	if !next.IsValid() {
		panic("tokeninfo: invalid admin address")
	}
	admin = next
	chain.Emit("AdminTransferred", "admin", next.String())
}

// Admin returns the moderation address.
func Admin() address { return admin }

func assertAdmin(cur realm) {
	if !cur.IsCurrent() {
		panic("tokeninfo: invalid realm")
	}
	if cur.Previous().Address() != admin {
		panic("tokeninfo: admin only")
	}
}
