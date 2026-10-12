package item

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderHomeAndOwner(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)

	home := Render("")
	uassert.True(t, strings.Contains(home, `<gno-form path="owner">`), "should render the owner lookup form")
	uassert.True(t, strings.Contains(home, `name="address"`), "should render the address input")

	empty := Render("owner?address=" + itemTest.Owner.String())
	uassert.True(t, strings.Contains(empty, itemTest.Owner.String()), "should render the owner address")
	uassert.True(t, strings.Contains(empty, "Total**: 0"), "should render an empty total")
	uassert.True(t, strings.Contains(empty, "No items held"), "should render an empty holding list")

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "test-iron", 3)
	SafeMint(cross(cur), itemTest.Owner, "**x**", 2)

	listed := Render("owner?address=" + itemTest.Owner.String())
	uassert.True(t, strings.Contains(listed, "Total**: 2"), "should render the owned token count")
	uassert.True(t, strings.Contains(listed, "test\\-iron"), "should escape item token ids")
	uassert.True(t, strings.Contains(listed, "**: 3"), "should render item amounts")
	uassert.True(t, strings.Contains(listed, `\*\*x\*\*`), "escaped markdown token id should be visible")
	uassert.False(t, strings.Contains(listed, "**x**"), "raw markdown token id should not remain")
}

func TestRenderOwnerPagesWhenCountExceedsLimit(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)
	testing.SetOriginCaller(itemTest.Admin)
	testing.SetRealm(testing.NewUserRealm(itemTest.Admin))
	SetListLimit(cross(cur), 1)

	testing.SetOriginCaller(itemTest.Operator)
	testing.SetRealm(testing.NewUserRealm(itemTest.Operator))
	SafeMint(cross(cur), itemTest.Owner, "10", 1)
	SafeMint(cross(cur), itemTest.Owner, "20", 1)

	page1 := Render("owner?address=" + itemTest.Owner.String())
	uassert.True(t, strings.Contains(page1, "Total**: 2"), "should render total holdings")
	uassert.True(t, strings.Contains(page1, "**10**"), "page 1 should include the first token")
	uassert.False(t, strings.Contains(page1, "**20**"), "page 1 should not include the second token")
	uassert.True(t, strings.Contains(page1, "page 1 of 2"), "should render a page picker")
	uassert.True(t, strings.Contains(page1, "page=2"), "should link to the next page")

	page2 := Render("owner?address=" + itemTest.Owner.String() + "&page=2")
	uassert.True(t, strings.Contains(page2, "**20**"), "page 2 should include the second token")
	uassert.False(t, strings.Contains(page2, "**10**"), "page 2 should not include the first token")
	uassert.True(t, strings.Contains(page2, "page 2 of 2"), "should render the last page picker")

	invalidPage := Render("owner?address=" + itemTest.Owner.String() + "&page=3")
	uassert.True(t, strings.Contains(invalidPage, "Invalid page"), "should reject a page past the last page")
}

func TestRenderErrors(cur realm, t *testing.T) {
	setupItemTest(cross(cur), t)

	invalid := Render("owner?address=invalid-address")
	uassert.True(t, strings.Contains(invalid, "Invalid address"), "should reject an invalid address")

	unknown := Render("unknown")
	uassert.True(t, strings.Contains(unknown, "Not found"), "should reject an unknown route")
}

func TestRenderRejectsOversizedURL(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "url exceeds max runes", func() {
		Render(strings.Repeat("a", renderURLMaxRunes+1))
	})
	Render(strings.Repeat("a", renderURLMaxRunes))
}
