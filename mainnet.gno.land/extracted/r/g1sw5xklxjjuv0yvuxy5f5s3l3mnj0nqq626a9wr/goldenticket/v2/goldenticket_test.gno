package goldenticket

import (
	"strings"
	"testing"

	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	aliceAddr = testutils.TestAddress("alice")
	bobAddr   = testutils.TestAddress("bob")
)

// reset redoes what init does on chain, with alice as the publisher.
func reset(cur realm) {
	func(cur realm) {
		bootstrap(aliceAddr, cur)
	}(cross(cur))
}

// The reads, called as Adena calls them: the id a quoted string, two values.
func TestReads(cur realm, t *testing.T) {
	reset(cur)

	owner, err := OwnerOf("1")
	uassert.NoError(t, err)
	uassert.Equal(t, aliceAddr, owner)

	n, err := BalanceOf(aliceAddr)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(1), n)
	n, err = BalanceOf(bobAddr)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(0), n)

	uri, err := TokenURI("1")
	uassert.NoError(t, err)
	uassert.Equal(t, defaultImage, uri)
	uassert.True(t, strings.HasPrefix(uri, "https://"))

	meta, err := TokenMetadata("1")
	uassert.NoError(t, err)
	uassert.Equal(t, `{"name":"Golden Ticket #1","description":"A 1/1 on gno.land, minted to check that collections show in Adena.",`+
		`"image":"`+defaultImage+`","attributes":[{"traitType":"edition","value":"1 of 1"},{"traitType":"metal","value":"gold"}]}`, meta)

	uassert.Equal(t, int64(1), Token.TotalSupply())
	uassert.Equal(t, "Golden Ticket", Name())
	uassert.Equal(t, "GOLD", Symbol())

	// Any other id is an error, not a panic.
	for _, bad := range []grc721.TokenID{"", "0", "2", "01", " 1"} {
		_, err = OwnerOf(bad)
		uassert.ErrorContains(t, err, errNoTicket, string(bad))
		_, err = TokenURI(bad)
		uassert.ErrorContains(t, err, errNoTicket, string(bad))
		_, err = TokenMetadata(bad)
		uassert.ErrorContains(t, err, errNoTicket, string(bad))
	}
}

func TestTransfer(cur realm, t *testing.T) {
	reset(cur)

	// Only the holder moves the ticket.
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	uassert.AbortsWithMessage(t, cur, errNotOwner, func() {
		Transfer(cross(cur), bobAddr)
	})

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	uassert.AbortsWithMessage(t, cur, errBadOwner, func() {
		Transfer(cross(cur), address("nope"))
	})
	Transfer(cross(cur), bobAddr)
	owner, err := OwnerOf("1")
	uassert.NoError(t, err)
	uassert.Equal(t, bobAddr, owner)
	n, _ := BalanceOf(aliceAddr)
	uassert.Equal(t, int64(0), n)
	n, _ = BalanceOf(bobAddr)
	uassert.Equal(t, int64(1), n)

	// Not through another realm.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/relay"))
	uassert.AbortsWithMessage(t, cur, errNotOwner, func() {
		Transfer(cross(cur), aliceAddr)
	})
}

func TestRender(cur realm, t *testing.T) {
	reset(cur)
	out := Render("")
	uassert.True(t, strings.Contains(out, "# Golden Ticket\n"))
	uassert.True(t, strings.Contains(out, "!["+tokenName+"]("+defaultImage+")"))
	uassert.True(t, strings.Contains(out, "Held by `"+aliceAddr.String()+"`."))
}

func TestSetImage(cur realm, t *testing.T) {
	reset(cur)
	uassert.Equal(t, aliceAddr, Admin())
	uassert.Equal(t, defaultImage, Image())

	// Only the admin, and not through another realm.
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	uassert.AbortsWithMessage(t, cur, errNotAdmin, func() {
		SetImage(cross(cur), "https://example.org/a.png")
	})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/relay"))
	uassert.AbortsWithMessage(t, cur, errNotAdmin, func() {
		SetImage(cross(cur), "https://example.org/a.png")
	})

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	for _, bad := range []string{
		"", "http://example.org/a.png", "https://", "javascript:alert(1)",
		"https://example.org/a b.png", `https://example.org/"a.png`, "https://example.org/a.png)![x](y",
		"https://example.org/" + strings.Repeat("a", 300),
	} {
		uassert.AbortsWithMessage(t, cur, errBadImage, func() {
			SetImage(cross(cur), bad)
		})
	}

	next := "https://ipfs.io/ipfs/bafy123/ticket.png?size=350&v=2"
	SetImage(cross(cur), next)
	uassert.Equal(t, next, Image())
	uri, err := TokenURI("1")
	uassert.NoError(t, err)
	uassert.Equal(t, next, uri)
	meta, _ := TokenMetadata("1")
	uassert.True(t, strings.Contains(meta, `"image":"`+next+`"`))
	uassert.True(t, strings.Contains(Render(""), "("+next+")"))

	// The admin stays the publisher after the ticket moves.
	Transfer(cross(cur), bobAddr)
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	uassert.AbortsWithMessage(t, cur, errNotAdmin, func() {
		SetImage(cross(cur), defaultImage)
	})
}
