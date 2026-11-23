package erratabank

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	testOwner  = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	testReader = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	testOther  = address("g1juz2yxmdsa6audkp6ep9vfv80c8p5u76e03vvh")
	testLink   = "https://example.org/book"
)

func assertPanic(t *testing.T, got any, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("panic = %v, want %q", got, want)
	}
}

func wantText(t *testing.T, got string, parts ...string) {
	t.Helper()
	for _, part := range parts {
		if !strings.Contains(got, part) {
			t.Errorf("expected %q in %q", part, got)
		}
	}
}

func TestBookValidationAndSubmission(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	assertPanic(t, revive(func() { CreateBook(cross(cur), "", "First", testLink, 0) }),
		"title must contain 1 to 120 characters")
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Book", "", testLink, 0) }),
		"edition must contain 1 to 120 characters")
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Book", "First", strings.Repeat("a", 301), 0) }),
		"link must contain 1 to 300 characters")
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Book", "First", "javascript:bad", 0) }),
		"unsupported book link")
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Book", "First", testLink, -1) }),
		"reward cannot be negative")

	id := CreateBook(cross(cur), "Book", "First", testLink, 0)
	assertPanic(t, revive(func() { Submit(cross(cur), id, "Page 1", "Fix") }), errSelfSubmit)

	testing.SetRealm(testing.NewUserRealm(testReader))
	assertPanic(t, revive(func() { Submit(cross(cur), id, " ", "Fix") }),
		"location must contain 1 to 120 characters")
	assertPanic(t, revive(func() { Submit(cross(cur), id, strings.Repeat("é", 121), "Fix") }),
		"location must contain 1 to 120 characters")
	assertPanic(t, revive(func() { Submit(cross(cur), id, "Page 1", "") }),
		"text must contain 1 to 1000 characters")
	assertPanic(t, revive(func() { Submit(cross(cur), id, "Page 1", strings.Repeat("a", 1001)) }),
		"text must contain 1 to 1000 characters")

	testing.SetRealm(testing.NewUserRealm(testOwner))
	SetBookOpen(cross(cur), id, false)
	testing.SetRealm(testing.NewUserRealm(testReader))
	assertPanic(t, revive(func() { Submit(cross(cur), id, "Page 1", "Fix") }), errClosed)
	testing.SetRealm(testing.NewUserRealm(testOwner))
	SetBookOpen(cross(cur), id, true)

	testing.SkipHeights(2)
	testing.SetRealm(testing.NewUserRealm(testReader))
	reportID := Submit(cross(cur), id, strings.Repeat("é", 120), strings.Repeat("a", 1000))
	report, ok := GetErratum(reportID)
	if !ok || report.Finder != testReader || report.SubmittedAt != runtime.ChainHeight() || report.Status != Pending {
		t.Fatalf("unexpected report %#v", report)
	}
	book, ok := GetBook(id)
	if !ok || book.Owner != testOwner || !book.Open {
		t.Fatalf("unexpected book %#v", book)
	}

	// Cross-realm consumers get detached value data.
	book.Title = "modified"
	report.Status = Accepted
	again, _ := GetBook(id)
	againReport, _ := GetErratum(reportID)
	if again.Title != "Book" || againReport.Status != Pending {
		t.Fatal("editing an exported copy affected realm state")
	}
}

func TestFirstFinderAndPermissions(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	bookID := CreateBook(cross(cur), "Duplicate test", "First", testLink, 0)
	otherBookID := CreateBook(cross(cur), "Another book", "First", testLink, 0)
	testing.SetRealm(testing.NewUserRealm(testReader))
	first := Submit(cross(cur), bookID, "Page 2", "Fix the number.")
	testing.SetRealm(testing.NewUserRealm(testOther))
	second := Submit(cross(cur), bookID, "Page 2", "Fix the number.")
	other := Submit(cross(cur), otherBookID, "Page 2", "Fix the number.")
	rejected := Submit(cross(cur), bookID, "Page 3", "Suggested wording.")
	late := Submit(cross(cur), bookID, "Page 4", "Another suggestion.")
	latest := Submit(cross(cur), bookID, "Page 4", "A later correction.")
	assertPanic(t, revive(func() { Accept(cross(cur), first, "") }), errOwnerOnly)
	assertPanic(t, revive(func() { Reject(cross(cur), first, "") }), errOwnerOnly)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), second, first) }), errOwnerOnly)
	assertPanic(t, revive(func() { Withdraw(cross(cur), bookID, 1) }), errOwnerOnly)
	assertPanic(t, revive(func() { SetBookOpen(cross(cur), bookID, false) }), errOwnerOnly)

	original, _ := GetErratum(first)
	later, _ := GetErratum(second)
	if original.SubmittedAt != later.SubmittedAt || first >= second {
		t.Fatal("same-height submissions must retain transaction order")
	}
	testing.SetRealm(testing.NewUserRealm(testOwner))
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), second, first) }), errDuplicate)
	Accept(cross(cur), first, "Confirmed")
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), other, first) }), errDuplicate)
	MarkDuplicate(cross(cur), second, first)
	Reject(cross(cur), rejected, "Editorial preference")
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), late, rejected) }), errDuplicate)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), late, second) }), errDuplicate)
	assertPanic(t, revive(func() { Accept(cross(cur), second, "") }), errPendingOnly)
	assertPanic(t, revive(func() { Accept(cross(cur), first, "") }), errPendingOnly)
	assertPanic(t, revive(func() { Reject(cross(cur), rejected, "") }), errPendingOnly)

	duplicate, _ := GetErratum(second)
	entries := AcceptedEntries(bookID)
	count, paid := FinderStats(testReader)
	otherCount, _ := FinderStats(testOther)
	if duplicate.DuplicateOf != first || duplicate.Status != Duplicate ||
		len(entries) != 1 || count != 1 || paid != 0 || otherCount != 0 {
		t.Fatal("duplicate status or finder credit is wrong")
	}
	duplicates := ListErrata(bookID, Duplicate, 0, 10)
	if len(duplicates) != 1 || duplicates[0].ID != second {
		t.Fatal("duplicate index is wrong")
	}

	Accept(cross(cur), latest, "Confirmed")
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), late, latest) }), errDuplicate)
}

func TestPayableGuards(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	id := CreateBook(cross(cur), "Payment test", "First", testLink, 100)
	assertPanic(t, revive(func() { FundBook(cross(cur), id) }), errPayment)

	testing.SetOriginSend(chain.Coins{{Denom: "utest", Amount: 100}})
	assertPanic(t, revive(func() { FundBook(cross(cur), id) }), errPaymentDenom)
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Payment test", "First", testLink, 100) }), errPaymentDenom)

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 0}})
	assertPanic(t, revive(func() { FundBook(cross(cur), id) }), errPayment)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: -10}})
	assertPanic(t, revive(func() { FundBook(cross(cur), id) }), errPayment)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 100}})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/paymentcaller"))
	assertPanic(t, revive(func() { FundBook(cross(cur), id) }), errDirectCall)
	assertPanic(t, revive(func() { CreateBook(cross(cur), "Payment test", "First", testLink, 100) }), errDirectCall)
	book, _ := GetBook(id)
	if book.Escrow != 0 {
		t.Fatal("invalid funding was credited")
	}
	testing.SetOriginSend(nil)
}

func TestNonpayableCallsRejectCoins(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	bookID := CreateBook(cross(cur), "Nonpayable calls", "First", testLink, 0)
	testing.SetRealm(testing.NewUserRealm(testReader))
	first := Submit(cross(cur), bookID, "Page 1", "First correction.")
	pending := Submit(cross(cur), bookID, "Page 2", "Second correction.")
	testing.SetRealm(testing.NewUserRealm(testOwner))
	Accept(cross(cur), first, "Confirmed")

	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	testing.SetRealm(testing.NewUserRealm(testReader))
	assertPanic(t, revive(func() { Submit(cross(cur), bookID, "Page 3", "Third correction.") }), errRejectCoins)

	testing.SetRealm(testing.NewUserRealm(testOwner))
	assertPanic(t, revive(func() { Accept(cross(cur), pending, "") }), errRejectCoins)
	assertPanic(t, revive(func() { Reject(cross(cur), pending, "") }), errRejectCoins)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), pending, first) }), errRejectCoins)
	assertPanic(t, revive(func() { SetBookOpen(cross(cur), bookID, false) }), errRejectCoins)
	assertPanic(t, revive(func() { Withdraw(cross(cur), bookID, 1) }), errRejectCoins)

	// A crossing from another realm does not receive the caller's origin send.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/nonpayablecaller"))
	Submit(cross(cur), bookID, "Page 3", "Third correction.")
	testing.SetOriginSend(nil)
}

func TestRenderAndPagination(cur realm, t *testing.T) {
	hostile := "[x](javascript:bad) *fix* | <img>\n# line"
	testing.SetRealm(testing.NewUserRealm(testOwner))
	bookID := CreateBook(cross(cur), hostile, "First edition", testLink, 0)
	bookPath := "book/" + strconv.Itoa(bookID)

	testing.SetRealm(testing.NewUserRealm(testReader))
	first := Submit(cross(cur), bookID, "Page 1", hostile)
	for i := 2; i <= pageSize+1; i++ {
		Submit(cross(cur), bookID, "Page "+strconv.Itoa(i), "Fix "+strconv.Itoa(i))
	}
	wantText(t, Render(bookPath+"/pending?page=2"), "Page 2 of 2", "Page 21")
	wantText(t, Render(bookPath+"/all?page=2"), "Page 2 of 2", "Page 21")

	testing.SetRealm(testing.NewUserRealm(testOwner))
	Accept(cross(cur), first, hostile)
	wantText(t, Render(""), "# Erratabank", bookURL(bookID), "Started 23 Nov 2026 for Gnome Tavern.")
	out := Render(bookPath)
	wantText(t, out, "## Accepted errata", finderURL(testReader), "Pending (20)", sanitize.TableCell(hostile))
	wantText(t, Render("erratum/"+strconv.Itoa(first)), "Status history", "Pending (submitted)", "Accepted",
		sanitize.InlineText(hostile))
	wantText(t, Render("finder/"+testReader.String()), "Finder account", "Accepted finds:", bookURL(bookID))
	wantText(t, Render("finder/invalid"), "Finder not found")
	wantText(t, Render("unknown"), "Page not found")
	wantText(t, Render(bookPath+"/all?page=3"), "Page not found")
	if strings.Contains(out, "](javascript:") || strings.Contains(out, "<img>") {
		t.Fatalf("unsafe Markdown in book page: %s", out)
	}
}
