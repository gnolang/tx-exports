package user

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/jeronimoalbi/pager/v0"
	"gno.land/r/akkadia/beta/admin"
)

// Render handles RESTful routing and returns Markdown responses.
func Render(iUrl string) string {
	assertRenderURLLen(iUrl)
	u, err := url.Parse(iUrl)
	if err != nil {
		return "404\n"
	}

	query := u.Query()

	switch u.Path {
	case "":
		return renderHome()
	case "users":
		return renderUsersList(iUrl)
	case "user":
		addr := address(query.Get("address"))
		return renderUser(iUrl, addr)
	default:
		return renderError("Not found")
	}
}

func renderHome() string {
	output := `# AKKADIA User

## Introduction

User realm stores address-keyed profiles for AKKADIA.

- **created_at**: recorded when the user is created
- **properties**: admin-managed key/value attributes

## Stats

`
	output += "* **Total Users**: " + strconv.Itoa(GetTotalUserSize()) + "\n"
	output += `
## Quick Links

* [Browse Users](./user:users)

## User Lookup

<gno-form path="user">
  <gno-input name="address" placeholder="Enter the address" />
</gno-form>
`
	return output
}

func renderUsersList(iUrl string) string {
	output := "# Users\n\n"
	output += "[← Home](./user:)\n\n"

	totalUsers := GetTotalUserSize()
	if totalUsers == 0 {
		output += "*No users registered yet.*\n"
		return output
	}

	pages, err := pager.New(iUrl, totalUsers, pager.WithPageSize(20))
	if err != nil {
		return renderError("Invalid page")
	}

	currentPage := pages.Page()
	addrStrs := ListUsers(currentPage, pages.PageSize())
	for _, addrStr := range addrStrs {
		nickname := ""
		listed := ListUsersByAddresses(address(addrStr))
		if len(listed) > 0 {
			nickname = listed[0]["nickname"]
		}
		if nickname != "" {
			output += "* [" + escapeMarkdown(nickname) + " (" + addrStr + ")](./user:user?address=" + addrStr + "&page=" + strconv.Itoa(currentPage) + ")\n"
		} else {
			output += "* [" + addrStr + "](./user:user?address=" + addrStr + "&page=" + strconv.Itoa(currentPage) + ")\n"
		}
	}

	if pages.HasPages() {
		output += "\n" + pager.Picker(pages)
	}

	return output
}

func renderUser(iUrl string, addr address) string {
	if !addr.IsValid() {
		return renderError("Invalid address")
	}

	u, _ := url.Parse(iUrl)
	page := normalizeRenderPage(u.Query().Get("page"))

	addrStr := addr.String()
	if !HasUser(addr) {
		return renderError("User not found")
	}

	users := ListUsersByAddresses(addr)

	output := "# User Detail\n\n"
	if page != "" {
		output += "[← Back to List](./user:users?page=" + page + ")\n\n"
	} else {
		output += "[← Home](./user:)\n\n"
	}
	output += "* **Address**: " + addrStr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + addrStr + ")]\n\n"

	if len(users) > 0 {
		output += "## Properties\n\n"
		for k, v := range users[0] {
			if k == "address" {
				continue
			}
			output += "* **" + escapeMarkdown(k) + "**: " + escapeMarkdown(v) + "\n"
		}
	}

	return output
}

func normalizeRenderPage(rawPage string) string {
	if rawPage == "" {
		return ""
	}
	page, err := strconv.Atoi(rawPage)
	if err != nil || page < 1 {
		return ""
	}
	return strconv.Itoa(page)
}

func renderError(message string) string {
	output := "# Error\n\n"
	output += "> " + message + "\n\n"
	output += "[← Back to Home](./user:)\n"
	return output
}

func escapeMarkdown(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "`", "\\`")
	s = strings.ReplaceAll(s, "*", "\\*")
	s = strings.ReplaceAll(s, "_", "\\_")
	s = strings.ReplaceAll(s, "{", "\\{")
	s = strings.ReplaceAll(s, "}", "\\}")
	s = strings.ReplaceAll(s, "[", "\\[")
	s = strings.ReplaceAll(s, "]", "\\]")
	s = strings.ReplaceAll(s, "(", "\\(")
	s = strings.ReplaceAll(s, ")", "\\)")
	s = strings.ReplaceAll(s, "#", "\\#")
	s = strings.ReplaceAll(s, "+", "\\+")
	s = strings.ReplaceAll(s, "-", "\\-")
	s = strings.ReplaceAll(s, ".", "\\.")
	s = strings.ReplaceAll(s, "!", "\\!")
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, ">", "\\>")
	return s
}
