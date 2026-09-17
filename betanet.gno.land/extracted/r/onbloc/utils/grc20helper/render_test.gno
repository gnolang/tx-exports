package grc20helper

import (
	"strings"
	"testing"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
)

// The listing must always report the registry's own total, whatever seeded it.
func TestRenderListHeader(t *testing.T) {
	size := grc20reg.GetRegistry().Size()
	got := Render("")

	if size == 0 {
		if !strings.Contains(got, "No registered token.") {
			t.Errorf("expected empty-registry notice, got:\n%s", got)
		}
		return
	}

	want := ufmt.Sprintf("%d registered token(s)", size)
	if !strings.Contains(got, want) {
		t.Errorf("expected %q in listing, got:\n%s", want, got)
	}
}

func TestRenderUnknownToken(t *testing.T) {
	got := Render("gno.land/r/demo/nope.NOPE")
	if !strings.Contains(got, "Unknown token") {
		t.Errorf("expected unknown-token notice, got:\n%s", got)
	}
}

func TestRenderTokenDetail(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/onbloc/testfoo"))
	token, ledger := grc20.NewToken("Foo Token", "FOO", 6, 0, cur)
	ledger.Mint(cur.Address(), 1234567)
	key := grc20reg.Register(cross(cur), token, "")

	list := Render("")
	if !strings.Contains(list, "Foo Token") {
		t.Errorf("list missing token name:\n%s", list)
	}
	if !strings.Contains(list, key) {
		t.Errorf("list missing registry key %q:\n%s", key, list)
	}

	// Each entry must link to this realm's subpage for the token, using an
	// absolute path — not to the caller's realm, and not relative.
	wantLink := "(/r/onbloc/utils/grc20helper:" + key + ")"
	if !strings.Contains(list, wantLink) {
		t.Errorf("list missing subpage link %q:\n%s", wantLink, list)
	}

	detail := Render(key)
	for _, want := range []string{
		"# Foo Token",
		"symbol: **FOO**",
		"decimals: 6",
		"total supply: 1234567",
		`<gno-form exec="Transfer">`,
		`<gno-input name="tokenKey"`,
		`<gno-input name="to"`,
		`<gno-input name="amount"`,
	} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail missing %q:\n%s", want, detail)
		}
	}

	// The transfer form's fields map to arguments by order, and `cur realm` is
	// never one of them, so the order must stay tokenKey, to, amount.
	iKey := strings.Index(detail, `name="tokenKey"`)
	iTo := strings.Index(detail, `name="to"`)
	iAmount := strings.Index(detail, `name="amount"`)
	if !(iKey < iTo && iTo < iAmount) {
		t.Errorf("transfer form fields out of order: tokenKey=%d to=%d amount=%d", iKey, iTo, iAmount)
	}
}

// Registering more than pageSize tokens must split the listing into pages.
// The registry is shared across tests in this package, so page sizes are
// checked against its actual total rather than against the count added here.
func TestRenderPaging(cur realm, t *testing.T) {
	for i := 0; i < pageSize+5; i++ {
		suffix := ufmt.Sprintf("%02d", i)
		testing.SetRealm(testing.NewCodeRealm("gno.land/r/onbloc/tk" + suffix))
		token, ledger := grc20.NewToken("Token "+suffix, "TK"+suffix, 6, 0, cur)
		ledger.Mint(cur.Address(), 1000)
		grc20reg.Register(cross(cur), token, "")
	}

	total := grc20reg.GetRegistry().Size()
	if total <= pageSize {
		t.Fatalf("test needs more than %d tokens to page, got %d", pageSize, total)
	}

	page1 := Render("")
	if n := strings.Count(page1, "- ["); n != pageSize {
		t.Errorf("page 1 should list %d items, got %d", pageSize, n)
	}
	if !strings.Contains(page1, "?page=2") {
		t.Errorf("page 1 missing pager link:\n%s", page1)
	}

	// The last page holds the remainder; a full division means a full page.
	wantLast := total % pageSize
	if wantLast == 0 {
		wantLast = pageSize
	}
	lastPage := total / pageSize
	if total%pageSize != 0 {
		lastPage++
	}

	got := Render(ufmt.Sprintf("?page=%d", lastPage))
	if n := strings.Count(got, "- ["); n != wantLast {
		t.Errorf("page %d should list %d items, got %d", lastPage, wantLast, n)
	}
}
