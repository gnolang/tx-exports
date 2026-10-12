package craft

import (
	"net/url"
	"strconv"
	"strings"
)

func Render(iURL string) string {
	u, err := url.Parse(iURL)
	if err != nil {
		return renderRecipeError("Invalid URL")
	}

	switch u.Path {
	case "":
		return renderRecipeHome()
	case "recipe":
		return renderRecipeResult(u.Query().Get("recipe"))
	case "recipes":
		return renderRecipeList(u.Query().Get("page"))
	default:
		return renderRecipeError("Not found")
	}
}

func renderRecipeHome() string {
	return `# AKKADIA Recipe

Ingredients are bound to occupied occupancy bits from slot 0 upward.

Current craft fee is ` + strconv.FormatInt(GetCraftFee(), 10) + `ugnot.

Enter a recipe to find its item ID.

<gno-form path="recipe">
  <gno-input name="recipe" placeholder="0013|iron:1|iron:2|stick:3" />
</gno-form>

* [Browse Recipes](./craft:recipes)
`
}

func renderRecipeList(rawPage string) string {
	page := 1
	if rawPage != "" {
		parsed, err := strconv.Atoi(rawPage)
		if err != nil || parsed < 1 {
			return renderRecipeError("Invalid page")
		}
		page = parsed
	}

	count := 20
	if count > listLimit {
		count = listLimit
	}

	output := `# Recipes

[← Back](./craft:)

`
	total := GetRecipeCount()
	if total == 0 {
		return output + `*No recipes stored yet.*
`
	}

	rows := ListRecipes(page, count)
	if len(rows) == 0 {
		return renderRecipeError("Invalid page")
	}
	for _, row := range rows {
		output += "* " + formatRecipeCode(row["recipe"]) + " → " + row["itemId"] + "\n"
	}
	return output
}

func renderRecipeResult(recipe string) string {
	if recipe == "" {
		return renderRecipeError("Recipe is required")
	}

	canonical, _, errMsg := parseRecipe(recipe)
	if errMsg != "" {
		return renderRecipeError("Invalid recipe")
	}
	if !recipes.Has(canonical) {
		return renderRecipeError("Recipe not found")
	}

	return `# Recipe Result

* **Recipe**: ` + formatRecipeCode(canonical) + `
* **Item ID**: ` + strconv.FormatUint(uint64(mustGetRecipeItemID(canonical)), 10) + `

[← Back](./craft:)
`
}

func renderRecipeError(message string) string {
	return `# Error

> ` + message + `

[← Back](./craft:)
`
}

// Recipes use | and - as syntax. A code span keeps those characters
// literal so gnoweb does not show backslash escapes.
func formatRecipeCode(recipe string) string {
	recipe = strings.ReplaceAll(recipe, "\n", " ")
	fence := "`"
	for strings.Contains(recipe, fence) {
		fence += "`"
	}
	return fence + recipe + fence
}
