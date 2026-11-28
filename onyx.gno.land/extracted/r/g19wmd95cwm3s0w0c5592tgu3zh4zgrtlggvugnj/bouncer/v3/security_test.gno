package bouncer

// Regressions from the security review (docs/security-review.md).

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

// Anyone can file disputes. Before the per-package index, Check() walked
// every dispute ever filed, so disputes on other packages made Check() on
// any package cost more, inside integrators' transactions (300 of them:
// 0.7M -> 14.8M gas).
func TestDisputesOnOtherPackagesDoNotReachCheck(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	attest(cur, "gno.land/r/demo/target", hash("c"), "", "")
	attest(cur, "gno.land/r/demo/other", hash("c"), "", "")
	for i := 0; i < 12; i++ {
		fund()
		testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("spam" + strconv.Itoa(i))))
		Dispute(cross(cur), "gno.land/r/demo/other", hash("e"), "spam <gno-form exec=\"TransferAdmin\"> [x](https://evil)")
	}
	uassert.True(t, Check("gno.land/r/demo/target", Strict()))
	uassert.True(t, Check("gno.land/r/demo/other", Strict())) // open disputes alone change nothing
	uassert.Equal(t, 0, OpenDisputes("gno.land/r/demo/target"))
	uassert.Equal(t, 0, len(DisputesFor("gno.land/r/demo/target")))
	uassert.Equal(t, 12, OpenDisputes("gno.land/r/demo/other"))
	uassert.Equal(t, 12, len(DisputesFor("gno.land/r/demo/other")))

	// The Passport lists only the newest 10, and escapes the notes.
	page := Render("realm/gno.land/r/demo/other")
	uassert.True(t, strings.Contains(page, "12 open of 12 filed. The newest 10 are shown."))
	uassert.Equal(t, 10, strings.Count(page, "spam \\<gno\\-form exec="))
	uassert.False(t, strings.Contains(page, "<gno-form exec=\"TransferAdmin\""))
	uassert.False(t, strings.Contains(page, "](https://evil)"))
}

func TestDisputeBookkeeping(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	attest(cur, "gno.land/r/demo/vault", hash("c"), "", "")
	fund()
	testing.SetRealm(testing.NewUserRealm(alice))
	id1 := Dispute(cross(cur), "gno.land/r/demo/vault", hash("e"), "first")
	fund()
	testing.SetRealm(testing.NewUserRealm(bob))
	id2 := Dispute(cross(cur), "gno.land/r/demo/vault", hash("e"), "second")
	uassert.Equal(t, 2, OpenDisputes("gno.land/r/demo/vault"))
	uassert.Equal(t, "1 gno.land/r/demo/vault "+rest+"\n2 gno.land/r/demo/vault "+rest+"\n", OpenDisputesText(10))
	uassert.Equal(t, "1 gno.land/r/demo/vault "+rest+"\n", OpenDisputesText(1))

	testing.SetRealm(testing.NewUserRealm(botAddr))
	SettleDispute(cross(cur), id1, hash("c"))
	uassert.Equal(t, 1, OpenDisputes("gno.land/r/demo/vault"))
	fund()
	testing.SetRealm(testing.NewUserRealm(alice)) // alice may file again
	id3 := Dispute(cross(cur), "gno.land/r/demo/vault", hash("e"), "third")
	testing.SetRealm(testing.NewUserRealm(botAddr))
	SettleDispute(cross(cur), id2, hash("c"))
	testing.SetRealm(testing.NewUserRealm(botAddr))
	SettleDispute(cross(cur), id3, hash("c"))
	uassert.Equal(t, 0, OpenDisputes("gno.land/r/demo/vault"))
	uassert.Equal(t, "", OpenDisputesText(10))
	ds := DisputesFor("gno.land/r/demo/vault")
	urequire.Equal(t, 3, len(ds))
	uassert.Equal(t, id1, ds[0].ID) // oldest first
	uassert.Equal(t, id3, ds[2].ID)
}

// Anyone can open requests (one per address). Before the per-package index,
// every Attest walked all open requests (300 of them: 2.8M -> 34.9M gas).
func TestAttestClosesOnlyItsOwnRequests(cur realm, t *testing.T) {
	reset()
	addBot(cur)
	for i := 0; i < 5; i++ {
		testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("req" + strconv.Itoa(i))))
		RequestScan(cross(cur), "gno.land/r/demo/other"+strconv.Itoa(i))
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	a := RequestScan(cross(cur), "gno.land/r/demo/vault")
	testing.SetRealm(testing.NewUserRealm(bob))
	b := RequestScan(cross(cur), "gno.land/r/demo/vault")
	testing.SetRealm(testing.NewUserRealm(bob))
	CancelRequest(cross(cur))
	testing.SetRealm(testing.NewUserRealm(bob))
	c := RequestScan(cross(cur), "gno.land/r/demo/vault")

	attest(cur, "gno.land/r/demo/vault", hash("c"), "", "")
	uassert.Equal(t, 5, len(OpenRequests(100)))
	for _, r := range OpenRequests(100) {
		uassert.True(t, strings.HasPrefix(r.PkgPath, "gno.land/r/demo/other"))
	}
	ra, _ := GetRequest(a)
	rb, _ := GetRequest(b)
	rc, _ := GetRequest(c)
	uassert.Equal(t, "attested", ra.Status)
	uassert.Equal(t, "cancelled", rb.Status) // not re-closed
	uassert.Equal(t, "attested", rc.Status)
	uassert.Equal(t, nil, openByPkg.Get("gno.land/r/demo/vault")) // emptied index is dropped

	// Closing by hand keeps the index in step too.
	testing.SetRealm(testing.NewUserRealm(botAddr))
	CloseRequest(cross(cur), 1, "package not found")
	attest(cur, "gno.land/r/demo/other0", hash("c"), "", "")
	uassert.Equal(t, 4, len(OpenRequests(100)))
}
