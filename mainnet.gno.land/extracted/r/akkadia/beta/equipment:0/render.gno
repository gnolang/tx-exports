package equipment

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
		return renderEquipmentError("Invalid URL")
	}

	switch u.Path {
	case "":
		return renderEquipmentHome()
	case "owner":
		return renderEquipmentOwner(iURL, address(u.Query().Get("address")))
	default:
		return renderEquipmentError("Not found")
	}
}

func renderEquipmentHome() string {
	return `# AKKADIA Equipment

Look up equipment held by an address.

<gno-form path="owner">
  <gno-input name="address" placeholder="Enter the address" />
</gno-form>
`
}

func renderEquipmentOwner(iURL string, owner address) string {
	if !owner.IsValid() {
		return renderEquipmentError("Invalid address")
	}

	output := `# Equipment Holdings

[← Home](./equipment:)

* **Address**: ` + owner.String() + `
`

	total := GetOwnedCount(owner)
	output += "* **Total**: " + strconv.Itoa(total) + "\n\n"
	if total == 0 {
		return output + `*No equipment held.*
`
	}

	pageSize := 20
	if pageSize > listLimit {
		pageSize = listLimit
	}
	pages, err := pager.New(iURL, total, pager.WithPageSize(pageSize))
	if err != nil {
		return renderEquipmentError("Invalid page")
	}

	rows := ListByOwner(owner, pages.Page(), pages.PageSize())
	for _, row := range rows {
		output += formatEquipmentHolding(row)
	}
	if pages.HasPages() {
		output += "\n" + pager.Picker(pages)
	}
	return output
}

func formatEquipmentHolding(row map[string]string) string {
	line := "* **" + escapeEquipmentMarkdown(row[tokenIDKey]) + "**: definitionId " + escapeEquipmentMarkdown(row[definitionIDKey])
	for key, value := range row {
		if key == tokenIDKey || key == definitionIDKey || key == createdAtKey {
			continue
		}
		line += " · " + escapeEquipmentMarkdown(key) + " " + escapeEquipmentMarkdown(value)
	}
	return line + "\n"
}

func renderEquipmentError(message string) string {
	return `# Error

> ` + escapeEquipmentMarkdown(message) + `

[← Home](./equipment:)
`
}

func escapeEquipmentMarkdown(value string) string {
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
