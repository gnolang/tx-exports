package user

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
	"gno.land/p/jeronimoalbi/pager"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

// Render handles RESTful routing and returns Markdown responses
func Render(iUrl string) string {
	assertMigrationStateAvailable()
	validate.AssertStringTextLen(iUrl, true, "url")
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
	case "nickname":
		nickname := query.Get("nickname")
		return renderNicknameLookup(nickname)
	default:
		return renderError("Not found")
	}
}

// renderHome renders the home page
func renderHome() string {
	output := `# AKKADIA User

## Introduction

User realm manages user profiles for AKKADIA.

- **metadata**: Admin-managed opaque user attributes
- **properties**: User-managed personal data
- **nicknames**: Exact-match unique nickname registry

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

## Nickname Lookup

<gno-form path="nickname">
  <gno-input name="nickname" placeholder="Enter the nickname" />
</gno-form>
`
	return output
}

// renderUsersList renders a list of all users with pagination
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

	// Get current page number for back links
	currentPage := (pages.Offset() / pages.PageSize()) + 1
	users := ListUsers(currentPage, pages.PageSize())

	for _, addrStr := range users {
		nickname := GetNickname(address(addrStr))
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

// renderUser renders a single user detail
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

	nickname := GetNickname(addr)
	metadata := ListUserMetadataByAddresses(addr)
	users := ListUsersByAddresses(addr)

	output := "# User Detail\n\n"
	if page != "" {
		output += "[← Back to List](./user:users?page=" + page + ")\n\n"
	} else {
		output += "[← Home](./user:)\n\n"
	}
	if nickname != "" {
		output += "* **Nickname**: " + escapeMarkdown(nickname) + "\n"
	}
	output += "* **Address**: " + addrStr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + addrStr + ")]\n\n"

	if len(metadata) > 0 && metadata[0] != "" {
		output += "## Metadata\n\n"
		output += escapeMarkdown(metadata[0]) + "\n"
		output += "\n"
	}

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

// renderNicknameLookup renders nickname search result
func renderNicknameLookup(nickname string) string {
	if nickname == "" {
		return renderError("Nickname is required")
	}

	if len(nickname) > 20 ||
		strings.TrimSpace(nickname) == "" ||
		strings.TrimSpace(nickname) != nickname ||
		isURLLikeNickname(nickname) ||
		hasControlChar(nickname) {
		return renderError("Invalid nickname")
	}

	if !HasNickname(nickname) {
		return renderError("User not found")
	}

	addr := GetAddressByNickname(nickname)
	return renderUser("", addr)
}

// renderError renders an error page
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
