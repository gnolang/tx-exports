package item

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/jeronimoalbi/pager/v0"
)

func Render(iURL string) string {
	assertRenderURLLen(iURL)
	u, err := url.Parse(iURL)
	if err != nil {
		return renderItemError("Invalid URL")
	}

	switch u.Path {
	case "":
		return renderItemHome()
	case "owner":
		return renderItemOwner(iURL, address(u.Query().Get("address")))
	default:
		return renderItemError("Not found")
	}
}

func renderItemHome() string {
	return `# AKKADIA Item

Look up fungible items held by an address.

<gno-form path="owner">
  <gno-input name="address" placeholder="Enter the address" />
</gno-form>
`
}

func renderItemOwner(iURL string, owner address) string {
	if !owner.IsValid() {
		return renderItemError("Invalid address")
	}

	output := `# Item Holdings

[← Home](./item:)

* **Address**: ` + owner.String() + `
`

	total := GetOwnedCount(owner)
	output += "* **Total**: " + strconv.Itoa(total) + "\n\n"
	if total == 0 {
		return output + `*No items held.*
`
	}

	pageSize := 20
	if pageSize > listLimit {
		pageSize = listLimit
	}
	pages, err := pager.New(iURL, total, pager.WithPageSize(pageSize))
	if err != nil {
		return renderItemError("Invalid page")
	}

	rows := ListByOwner(owner, pages.Page(), pages.PageSize())
	for _, row := range rows {
		output += "* **" + escapeItemMarkdown(row["tokenId"]) + "**: " + escapeItemMarkdown(row["amount"]) + "\n"
	}
	if pages.HasPages() {
		output += "\n" + pager.Picker(pages)
	}
	return output
}

func renderItemError(message string) string {
	return `# Error

> ` + escapeItemMarkdown(message) + `

[← Home](./item:)
`
}

func escapeItemMarkdown(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\n", "\\n")
	value = strings.ReplaceAll(value, "`", "\\`")
	value = strings.ReplaceAll(value, "*", "\\*")
	value = strings.ReplaceAll(value, "_", "\\_")
	value = strings.ReplaceAll(value, "{", "\\{")
	value = strings.ReplaceAll(value, "}", "\\}")
	value = strings.ReplaceAll(value, "[", "\\[")
	value = strings.ReplaceAll(value, "]", "\\]")
	value = strings.ReplaceAll(value, "(", "\\(")
	value = strings.ReplaceAll(value, ")", "\\)")
	value = strings.ReplaceAll(value, "#", "\\#")
	value = strings.ReplaceAll(value, "+", "\\+")
	value = strings.ReplaceAll(value, "-", "\\-")
	value = strings.ReplaceAll(value, ".", "\\.")
	value = strings.ReplaceAll(value, "!", "\\!")
	value = strings.ReplaceAll(value, "|", "\\|")
	value = strings.ReplaceAll(value, ">", "\\>")
	return value
}
