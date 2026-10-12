package equipment

import (
	"net/url"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderHomeAndOwner(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)

	home := Render("")
	uassert.True(t, strings.Contains(home, `<gno-form path="owner">`), "should render the owner lookup form")
	uassert.True(t, strings.Contains(home, `name="address"`), "should render the address input")

	empty := Render("owner?address=" + equipmentTest.Owner.String())
	uassert.True(t, strings.Contains(empty, equipmentTest.Owner.String()), "should render the owner address")
	uassert.True(t, strings.Contains(empty, "Total**: 0"), "should render an empty total")
	uassert.True(t, strings.Contains(empty, "No equipment held"), "should render an empty holding list")

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "enhancement", "3")
	Mint(cross(cur), equipmentTest.Owner, 1101001, "note", url.PathEscape("**x**"))

	listed := Render("owner?address=" + equipmentTest.Owner.String())
	uassert.True(t, strings.Contains(listed, "Total**: 2"), "should render the owned token count")
	uassert.True(t, strings.Contains(listed, "**1**"), "should render the first token id")
	uassert.True(t, strings.Contains(listed, "definitionId 1101000"), "should render the definition id")
	uassert.True(t, strings.Contains(listed, "enhancement 3"), "should render extra attributes")
	uassert.True(t, strings.Contains(listed, `\*\*x\*\*`), "should escape attribute markdown")
	uassert.False(t, strings.Contains(listed, "**x**"), "raw markdown attributes should not remain")
}

func TestRenderOwnerPagesWhenCountExceedsLimit(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)
	testing.SetOriginCaller(equipmentTest.Admin)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Admin))
	SetListLimit(cross(cur), 1)

	testing.SetOriginCaller(equipmentTest.Operator)
	testing.SetRealm(testing.NewUserRealm(equipmentTest.Operator))
	Mint(cross(cur), equipmentTest.Owner, 1101000, "", "")
	Mint(cross(cur), equipmentTest.Owner, 1101001, "", "")

	page1 := Render("owner?address=" + equipmentTest.Owner.String())
	uassert.True(t, strings.Contains(page1, "Total**: 2"), "should render total holdings")
	uassert.True(t, strings.Contains(page1, "**1**"), "page 1 should include the first token")
	uassert.False(t, strings.Contains(page1, "**2**"), "page 1 should not include the second token")
	uassert.True(t, strings.Contains(page1, "page 1 of 2"), "should render a page picker")
	uassert.True(t, strings.Contains(page1, "page=2"), "should link to the next page")

	page2 := Render("owner?address=" + equipmentTest.Owner.String() + "&page=2")
	uassert.True(t, strings.Contains(page2, "**2**"), "page 2 should include the second token")
	uassert.False(t, strings.Contains(page2, "**1**"), "page 2 should not include the first token")
	uassert.True(t, strings.Contains(page2, "page 2 of 2"), "should render the last page picker")

	invalidPage := Render("owner?address=" + equipmentTest.Owner.String() + "&page=3")
	uassert.True(t, strings.Contains(invalidPage, "Invalid page"), "should reject a page past the last page")
}

func TestRenderErrors(cur realm, t *testing.T) {
	setupEquipmentTest(cross(cur), t)

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
