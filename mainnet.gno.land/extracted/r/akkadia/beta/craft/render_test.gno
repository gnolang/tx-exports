package craft

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderRecipeLookup(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), "0001|craft-render-item:01", 1200)

	output := Render("recipe?recipe=0001%7Ccraft-render-item%3A1")
	uassert.True(t, strings.Contains(output, "Item ID**: 1200"), "should render the mapped item ID")
	uassert.True(t, strings.Contains(output, "`0001|0:craft-render-item:1`"), "should render the canonical recipe as a code span")
	uassert.False(t, strings.Contains(output, `\|`), "recipe code span should keep pipes literal")
}

func TestRenderRecipeErrors(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)

	empty := Render("recipe")
	uassert.True(t, strings.Contains(empty, "Recipe is required"), "should require a recipe")

	invalid := Render("recipe?recipe=bad")
	uassert.True(t, strings.Contains(invalid, "Invalid recipe"), "should reject an invalid recipe")

	missing := Render("recipe?recipe=0001%7Ccraft-missing-item%3A1")
	uassert.True(t, strings.Contains(missing, "Recipe not found"), "should report a missing recipe")

	unknown := Render("unknown")
	uassert.True(t, strings.Contains(unknown, "Not found"), "should reject an unknown route")
}

func TestRenderRecipeHomeAndList(cur realm, t *testing.T) {
	setupCraftTest(cross(cur), t)
	home := Render("")
	uassert.True(t, strings.Contains(home, `<gno-form path="recipe">`), "should render the recipe lookup form")
	uassert.True(t, strings.Contains(home, `name="recipe"`), "should render the recipe input")
	uassert.True(t, strings.Contains(home, `./craft:recipes`), "should link to the recipe list")
	uassert.True(t, strings.Contains(home, "1000000ugnot"), "should render the default craft fee")

	emptyList := Render("recipes")
	uassert.True(t, strings.Contains(emptyList, "No recipes stored yet"), "should render an empty list")

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	SetRecipe(cross(cur), "0001|craft-list-render:1", 1300)

	listed := Render("recipes")
	uassert.True(t, strings.Contains(listed, "1300"), "should render stored item IDs")
	uassert.True(t, strings.Contains(listed, "`0001|0:craft-list-render:1`"), "should render listed recipes as a code span")
	uassert.False(t, strings.Contains(listed, `\|`), "listed recipe code span should keep pipes literal")
}
