package bolo

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	registryPath  = "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo"
	versionPrefix = registryPath + "/v"

	// maxVersions keeps Versions() to one bounded read (INV-9).
	maxVersions = 50

	// maxPathLen is the longest package path the chain deploys: a longer one could
	// never hold a version.
	maxPathLen = 256
)

// The registry's state (API §3.7), all unexported (C6).
var (
	admin        address = adminAddr // a realm once a DAO accepts the role (ADR D11)
	pendingAdmin address             // the proposed admin until it accepts; "" for none

	versions []string // every version added, oldest first
	added    avl.Tree // path → true, for lookups
	current  string   // "" until the first SetCurrent
)

// The registry's events (API §6).
const (
	evVersionAdded  = "VersionAdded"
	evCurrentSet    = "CurrentSet"
	evAdminProposed = "AdminProposed"
	evAdminChanged  = "AdminChanged"
)

// Current returns the version new campaigns should use: a pkgpath, or "" before the
// first SetCurrent.
func Current() string { return current }

// Versions returns every version ever added, oldest first, as a copy.
func Versions() []string { return append([]string(nil), versions...) }

// GetAdmin returns the admin and the proposed admin, "" when there is none.
func GetAdmin() (address, address) { return admin, pendingAdmin }

// AddVersion registers a version. None is ever removed.
func AddVersion(cur realm, path string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	checkNewVersion(path)
	added.Set(path, true)
	versions = append(versions, path)
	chain.Emit(evVersionAdded, "path", path)
}

// SetCurrent points new campaigns, and their donors' money, at a version already
// added.
func SetCurrent(cur realm, path string) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	if !added.Has(path) {
		panic(ErrSetting)
	}
	current = path
	chain.Emit(evCurrentSet, "path", path)
}

// ProposeAdmin proposes next as the registry's admin, who takes over by accepting.
// A second proposal replaces the first.
func ProposeAdmin(cur realm, next address) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, admin)
	checkCandidate(next)
	pendingAdmin = next
	chain.Emit(evAdminProposed, "next", next.String())
}

// AcceptAdmin makes the proposed admin the admin, and ends the proposal.
func AcceptAdmin(cur realm) {
	assertCurrent(cur)
	if cur.Previous().IsUserCall() {
		runtime.AssertOriginCall()
	} else {
		assertCodeCaller(cur)
	}
	assertSigner(cur, pendingAdmin)
	previous := admin
	admin, pendingAdmin = pendingAdmin, ""
	chain.Emit(evAdminChanged, "admin", admin.String(), "previous", previous.String())
}

// Render is Bolo's front page on gnoweb, the twin of the web app's Home (UI spec §3,
// §4.13): the name, the tagline, a link to the current version, then the versions,
// oldest first, the current one marked. It ignores path: nothing a visitor types
// reaches the page (API §3.7).
func Render(path string) string {
	if len(versions) == 0 {
		return "# Bolo\n\nNo version is registered yet.\n"
	}
	var b strings.Builder
	b.WriteString("# Bolo\n\nGive together. See where it goes.\n\n")
	if current != "" {
		b.WriteString("**[Open Bolo](" + strings.TrimPrefix(current, "gno.land") + ")**, where new campaigns start.\n\n")
	}
	b.WriteString("## Versions\n\nEach campaign runs to its end on the version it started on: money never moves between versions.\n\n")
	for _, v := range versions {
		b.WriteString("- [" + v + "](" + strings.TrimPrefix(v, "gno.land") + ")")
		if v == current {
			b.WriteString(" — current")
		}
		b.WriteString("\n")
	}
	return b.String()
}

// checkNewVersion refuses, with ErrSetting, a path that isn't a version path, one
// already added, and one past the cap (API §3.7).
func checkNewVersion(path string) {
	if !isVersionPath(path) || added.Has(path) || len(versions) >= maxVersions {
		panic(ErrSetting)
	}
}

// isVersionPath reports whether path names a Bolo version (API §3.7), parsed by
// hand: exactly versionPrefix, then 0 or a number without a leading zero, and
// nothing else, in at most maxPathLen bytes. v012 would be another package than
// v12, so it is refused.
func isVersionPath(path string) bool {
	if len(path) > maxPathLen || !strings.HasPrefix(path, versionPrefix) {
		return false
	}
	n := path[len(versionPrefix):]
	if n == "" || (n[0] == '0' && len(n) > 1) {
		return false
	}
	for i := 0; i < len(n); i++ {
		if n[i] < '0' || n[i] > '9' {
			return false
		}
	}
	return true
}
