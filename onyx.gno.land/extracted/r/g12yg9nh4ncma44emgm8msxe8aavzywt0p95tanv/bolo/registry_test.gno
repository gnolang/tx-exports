package bolo

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func TestIsVersionPath(t *testing.T) {
	for _, path := range []string{
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v12",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v909",
		// The longest path the chain deploys: 256 bytes.
		versionPrefix + "1" + strings.Repeat("0", 256-len(versionPrefix)-1),
	} {
		if !isVersionPath(path) {
			t.Errorf("%s refused", path)
		}
	}
	for _, path := range []string{
		"",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1x",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1/x",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/V1",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1/../x",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v012",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v00",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v-1",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1 ",
		" gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1",
		"gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolov1",
		"gno.land/r/other/bolo/v1",
		"gno.land/p/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1",
		// One byte too long for the chain to ever deploy.
		versionPrefix + "1" + strings.Repeat("0", 256-len(versionPrefix)),
	} {
		if isVersionPath(path) {
			t.Errorf("%q accepted", path)
		}
	}
}

func TestCheckNewVersion(t *testing.T) {
	defer restoreVersions(versions)
	checkNewVersion("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v3")
	for name, path := range map[string]string{
		"not a version": "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v3x",
		"added already": "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0",
	} {
		added.Set("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0", true)
		if !panicsWith(func() { checkNewVersion(path) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
	// The 50th fits, the 51st doesn't (API §3.7, INV-9).
	for len(versions) < 49 {
		versions = append(versions, "filler")
	}
	checkNewVersion("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v50")
	versions = append(versions, "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v50")
	if !panicsWith(func() { checkNewVersion("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v51") }, ErrSetting) {
		t.Errorf("a 51st version: not refused")
	}
}

func TestCheckCandidate(t *testing.T) {
	checkCandidate(testutils.TestAddress("dao"))
	for name, a := range map[string]address{
		"the registry":        chain.PackageAddress("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo"),
		"its storage deposit": chain.DeriveStorageDepositAddr("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo"),
		"malformed":           "g1notanaddress",
		"in capitals":         address(strings.ToUpper(string(testutils.TestAddress("dao")))),
	} {
		if !panicsWith(func() { checkCandidate(a) }, ErrSetting) {
			t.Errorf("%s: not refused", name)
		}
	}
}

// TestRegistry walks a fresh registry, each write called straight from the test's
// body as AssertOriginCall requires (plan §3.3). The writes' refusals are tested in
// txtar (registry.txtar): a crossing call's panic can't be recovered here.
func TestRegistry(cur realm, t *testing.T) {
	defer restoreRegistry(admin, pendingAdmin, current, versions)
	if Current() != "" || len(Versions()) != 0 || !strings.Contains(Render(""), "No version is registered yet.") {
		t.Errorf("a fresh registry isn't empty")
	}
	if a, p := GetAdmin(); a != adminAddr || p != "" {
		t.Errorf("GetAdmin() = %s, %q", a, p)
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	AddVersion(cross(cur), "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0")
	AddVersion(cross(cur), "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1")
	// No version is current yet: the page links to none.
	if got := Render(""); strings.Contains(got, "Open Bolo") || !strings.Contains(got, "- [gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1)\n") {
		t.Errorf("Render before SetCurrent:\n%s", got)
	}
	SetCurrent(cross(cur), "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1")
	if Current() != "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1" {
		t.Errorf("Current() = %q", Current())
	}
	vs := Versions()
	if len(vs) != 2 || vs[0] != "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0" || vs[1] != "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1" {
		t.Errorf("Versions() = %v", vs)
	}
	// Versions hands out a copy (C6).
	vs[0] = "changed"
	if Versions()[0] != "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0" {
		t.Errorf("Versions shares its slice with the realm")
	}
	want := "# Bolo\n\nGive together. See where it goes.\n\n" +
		"**[Open Bolo](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1)**, where new campaigns start.\n\n" +
		"## Versions\n\nEach campaign runs to its end on the version it started on: money never moves between versions.\n\n" +
		"- [gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0)\n" +
		"- [gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v1) — current\n"
	if got := Render(""); got != want {
		t.Errorf("Render =\n%s\nwant\n%s", got, want)
	}
	// Render ignores its path.
	if got := Render("<b>x</b>?page=2"); got != want {
		t.Errorf("Render echoes its path:\n%s", got)
	}

	// The handover, to a realm, which then acts through C11's realm branch.
	dao := chain.PackageAddress("gno.land/r/test/dao")
	ProposeAdmin(cross(cur), testutils.TestAddress("someone"))
	ProposeAdmin(cross(cur), dao)
	if a, p := GetAdmin(); a != adminAddr || p != dao {
		t.Errorf("after two proposals: GetAdmin() = %s, %s", a, p)
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/dao"))
	AcceptAdmin(cross(cur))
	if a, p := GetAdmin(); a != dao || p != "" {
		t.Errorf("after accepting: GetAdmin() = %s, %q", a, p)
	}
	SetCurrent(cross(cur), "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0")
	if Current() != "gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0" {
		t.Errorf("the realm admin's write didn't apply")
	}
}

// restoreVersions puts back the versions list and its lookup tree.
func restoreVersions(saved []string) {
	for _, path := range versions[len(saved):] {
		added.Remove(path)
	}
	added.Remove("gno.land/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0")
	for _, path := range saved {
		added.Set(path, true)
	}
	versions = saved
}

// restoreRegistry puts back what TestRegistry changes.
func restoreRegistry(a, pending address, cur string, saved []string) {
	admin, pendingAdmin, current = a, pending, cur
	restoreVersions(saved)
}

// panicsWith reports whether f panics with err.
func panicsWith(f func(), err Error) (ok bool) {
	defer func() {
		r := recover()
		e, isErr := r.(Error)
		ok = isErr && e == err
	}()
	f()
	return false
}
