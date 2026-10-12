package user

import (
	"net/url"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderEscapesMarkdownSensitiveUserValues(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	nickname := "N [x](y) **b**"
	intro := "**bold** [link](https://example.invalid)\n# heading"

	createUserForTest(cross(cur), regularUser)
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AdminUpdateUser(cross(cur), regularUser, "nickname,introduction", url.PathEscape(nickname)+","+url.PathEscape(intro))

	detail := Render("user?address=" + regularUser.String())
	uassert.True(t, strings.Contains(detail, `N \[x\]\(y\) \*\*b\*\*`), "nickname should be escaped")
	uassert.True(t, strings.Contains(detail, `\*\*bold\*\* \[link\]\(https://example\.invalid\)\n\# heading`), "property value should be escaped")
	uassert.False(t, strings.Contains(detail, "[link](https://example.invalid)"), "property link syntax should not remain raw")
	uassert.False(t, strings.Contains(detail, "\n# heading"), "property newline heading should not remain raw")

	list := Render("users")
	uassert.True(t, strings.Contains(list, `N \[x\]\(y\) \*\*b\*\*`), "list nickname should be escaped")
	uassert.False(t, strings.Contains(list, "[profile](profile-page)"), "list nickname link syntax should not remain raw")
}

func TestRenderErrors(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	invalid := Render("user?address=invalid-address")
	uassert.True(t, strings.Contains(invalid, "Invalid address"), "render output should contain expected error")

	missing := Render("user?address=" + regularUser.String())
	uassert.True(t, strings.Contains(missing, "User not found"), "missing user should render not found")

	unknown := Render("nickname?nickname=alice")
	uassert.True(t, strings.Contains(unknown, "Not found"), "removed nickname route should 404")
}

func TestRenderUserSanitizesPageLink(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)
	createUserForTest(cross(cur), regularUser)

	valid := Render("user?address=" + regularUser.String() + "&page=02")
	uassert.True(t, strings.Contains(valid, "[← Back to List](./user:users?page=2)"), "valid page should be normalized")

	injected := Render("user?address=" + regularUser.String() + "&page=1%29%5D%28https%3A%2F%2Fexample.invalid%29")
	uassert.False(t, strings.Contains(injected, "example.invalid"), "invalid page should not be reflected")
	uassert.False(t, strings.Contains(injected, "users?page="), "invalid page should not render a page back link")
	uassert.True(t, strings.Contains(injected, "[← Home](./user:)"), "invalid page should fall back to home link")
}

func TestRenderRejectsOversizedURL(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "url exceeds max runes", func() {
		Render(strings.Repeat("a", renderURLMaxRunes+1))
	})
	Render(strings.Repeat("a", renderURLMaxRunes))
}

func TestRenderHomeUsesRelativeBrowseUsersLink(cur realm, t *testing.T) {
	setupUserTests(cross(cur), t)

	output := Render("")

	uassert.True(t, strings.Contains(output, "* [Browse Users](./user:users)"), "should use package-relative users link")
	uassert.False(t, strings.Contains(output, "* [Browse Users](users)"), "should not use path-relative users link")
	uassert.False(t, strings.Contains(output, "* [Browse Users](/r/akkadia/user:users)"), "should not use absolute users link")
}
