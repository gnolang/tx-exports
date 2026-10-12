package lotto

import (
	"net/url"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestRenderInput(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	home := Render("")
	uassert.True(t, strings.Contains(home, "# AKKADIA Lotto"))
	uassert.True(t, strings.Contains(home, `<gno-form path="number">`))
	uassert.True(t, strings.Contains(home, `name="number"`))
	for _, tc := range []struct{ path, message string }{
		{"%", "Invalid URL"},
		{"number?number=%zz", "Invalid query"},
		{"unknown", "Page not found"},
		{"number", "Number is required"},
		{"number?number=-1", "Invalid number"},
		{"number?number=1.5", "Invalid number"},
		{"number?number=18446744073709551616", "Invalid number"},
		{"number?number=" + url.QueryEscape(`<script>alert(1)</script>`), "Invalid number"},
		{"number?number=1&afterOwner=" + url.QueryEscape(`[x](javascript:alert(1))`), "Invalid cursor address"},
		{"number?number=1&afterOwner=invalid", "Invalid cursor address"},
	} {
		result := Render(tc.path)
		uassert.True(t, strings.Contains(result, tc.message))
		uassert.True(t, strings.Contains(result, `<gno-form path="number">`))
		uassert.False(t, strings.Contains(result, "<script>"))
		uassert.False(t, strings.Contains(result, "javascript:"))
	}
	for _, number := range []string{"0", "18446744073709551615"} {
		result := Render("number?number=" + number)
		uassert.True(t, strings.Contains(result, "## Number "+number+"\n"))
		uassert.True(t, strings.Contains(result, "No owners on this page."))
		uassert.False(t, strings.Contains(result, "[Next]"))
	}
	uassert.Equal(t, holdings.Size(), 0)
}

func TestRenderPagination(cur realm, t *testing.T) {
	setupLotto(cross(cur))
	for i := 0; i < 41; i++ {
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		owner := testutils.TestAddress("lottoRender" + strconv.Itoa(i))
		AddNumber(cross(cur), owner, 123)
		AddNumber(cross(cur), owner, 123)
	}
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	AddNumber(cross(cur), testOther, 1234)
	route := "number?number=000123"
	afterOwner := ""
	for _, expectedCount := range []int{20, 20, 1} {
		expected := ListOwnersByNumber(123, afterOwner, 20)
		result := Render(route)
		uassert.True(t, strings.Contains(result, "## Number 123\n"))
		uassert.True(t, strings.Contains(result, "[Home](./lotto:)"))
		uassert.False(t, strings.Contains(result, testOther.String()))
		uassert.Equal(t, strings.Count(result, " | 2 |\n"), expectedCount)
		uassert.Equal(t, strings.Contains(result, "[First page]"), afterOwner != "")
		previous := -1
		for _, item := range expected {
			position := strings.Index(result, "| "+item["owner"]+" | 2 |")
			uassert.True(t, position > previous)
			previous = position
			uassert.Equal(t, GetNumberCount(123, address(item["owner"])), uint64(2))
		}
		if expected[0]["nextOwner"] != "" {
			route = "number?number=123&afterOwner=" + url.QueryEscape(expected[0]["nextOwner"])
			uassert.True(t, strings.Contains(result, "[Next](./lotto:"+route+")"))
			afterOwner = expected[0]["nextOwner"]
		} else {
			uassert.False(t, strings.Contains(result, "[Next]"))
			last := expected[len(expected)-1]["owner"]
			uassert.True(t, strings.Contains(Render("number?number=123&afterOwner="+url.QueryEscape(last)), "No owners on this page."))
		}
	}
	uassert.Equal(t, holdings.Size(), 42)
}
