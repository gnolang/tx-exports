package erratabank

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	testOwner   = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	testReader  = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	testSponsor = address("g1juz2yxmdsa6audkp6ep9vfv80c8p5u76e03vvh")
	testLink    = "https://example.org/guide"
)

func assertPanic(t *testing.T, got any, want string) {
	t.Helper()
	if got != want {
		t.Fatalf("panic = %v, want %q", got, want)
	}
}

func TestReviewOrderAndPermissions(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	book := CreateBook(cross(cur), "Review order", "First edition", testLink, 0)
	otherBook := CreateBook(cross(cur), "Other book", "First edition", testLink, 0)
	testing.SetRealm(testing.NewUserRealm(testReader))
	first := Submit(cross(cur), book, " Section 1 ", "The first correction.")
	other := Submit(cross(cur), otherBook, "Section 1", "This location is in another book.")
	testing.SetRealm(testing.NewUserRealm(testSponsor))
	later := Submit(cross(cur), book, "Section 1", "The second correction.")
	assertPanic(t, revive(func() { Accept(cross(cur), first, "") }), errOwnerOnly)
	assertPanic(t, revive(func() { Reject(cross(cur), first, "") }), errOwnerOnly)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), later, first) }), errOwnerOnly)
	assertPanic(t, revive(func() { Withdraw(cross(cur), book, 1) }), errOwnerOnly)

	testing.SetRealm(testing.NewUserRealm(testOwner))
	assertPanic(t, revive(func() { Accept(cross(cur), later, "") }), errEarlierPending)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), first, later) }), errDuplicate)
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), later, other) }), errDuplicate)
	Accept(cross(cur), other, "")
	Accept(cross(cur), first, "")
	MarkDuplicate(cross(cur), later, first)
	duplicate, _ := GetErratum(later)
	if duplicate.Status != Duplicate || duplicate.DuplicateOf != first {
		t.Fatalf("wrong duplicate record: %+v", duplicate)
	}

	testing.SetRealm(testing.NewUserRealm(testReader))
	original := Submit(cross(cur), book, "Alternate section", "Report before Section 2.")
	firstAtLocation := Submit(cross(cur), book, "Section 2", "First at this location.")
	secondAtLocation := Submit(cross(cur), book, "Section 2", "Second at this location.")
	rejected := Submit(cross(cur), book, "Section 3", "Unconfirmed report.")
	confirmed := Submit(cross(cur), book, "Section 3", "Confirmed report.")
	testing.SetRealm(testing.NewUserRealm(testOwner))
	MarkDuplicate(cross(cur), firstAtLocation, original)
	Accept(cross(cur), secondAtLocation, "")
	Reject(cross(cur), rejected, "")
	assertPanic(t, revive(func() { MarkDuplicate(cross(cur), confirmed, rejected) }), errDuplicate)
	Accept(cross(cur), confirmed, "")
	pending, _ := GetErratum(original)
	if pending.Status != Pending {
		t.Fatalf("marking a duplicate changed the original status: %s", pending.Status)
	}
	assertPanic(t, revive(func() { Accept(cross(cur), first, "") }), errPendingOnly)
}

func TestFinderReputationAndOwed(cur realm, t *testing.T) {
	author := chain.PackageAddress("gno.land/r/test/reputationauthor")
	finder := chain.PackageAddress("gno.land/r/test/reputationfinder")
	testing.SetRealm(testing.NewUserRealm(author))
	rewarded := CreateBook(cross(cur), "Rewarded book", "First edition", testLink, 1000)
	creditOnly := CreateBook(cross(cur), "Credit-only book", "First edition", testLink, 0)
	self := Submit(cross(cur), rewarded, "Owner note", "A maintainer's own correction.")
	testing.SetRealm(testing.NewUserRealm(finder))
	eligible := Submit(cross(cur), rewarded, "Rewarded location", "A reader's correction.")
	unpaid := Submit(cross(cur), creditOnly, "Volunteer note", "A voluntary correction.")
	testing.SetRealm(testing.NewUserRealm(author))
	Accept(cross(cur), self, "")
	Accept(cross(cur), eligible, "")
	Accept(cross(cur), unpaid, "")

	owner := FinderStats(author)
	if owner.Credits != 0 || owner.UnpaidCredits != 1 || owner.Paid != 0 || owner.Owed != 0 {
		t.Fatalf("self-owned correction counted as a reward: %+v", owner)
	}
	reader := FinderStats(finder)
	if reader.Credits != 1 || reader.UnpaidCredits != 1 || reader.Paid != 0 || reader.Owed != 1000 {
		t.Fatalf("wrong reader reputation or reward ledger: %+v", reader)
	}
	path := "finder/" + finder.String()
	main := Render(path)
	if !strings.Contains(main, "Reward-eligible credits: 1") ||
		!strings.Contains(main, "Owed: 0.001 GNOT") ||
		!strings.Contains(main, "Paid: 0 GNOT") ||
		!strings.Contains(main, "Rewarded location") || strings.Contains(main, "Volunteer note") {
		t.Fatalf("wrong finder view: %s", main)
	}
	unpaidPage := Render(path + "/unpaid")
	if !strings.Contains(unpaidPage, "## Unpaid credits") ||
		!strings.Contains(unpaidPage, "Volunteer note") || strings.Contains(unpaidPage, "Rewarded location") {
		t.Fatalf("wrong unpaid page: %s", unpaidPage)
	}
}

func TestFundingAndClosureGuards(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	book := CreateBook(cross(cur), "Funding guards", "First edition", testLink, 1000)
	assertPanic(t, revive(func() { FundBook(cross(cur), book) }), errPayment)
	testing.SetOriginSend(chain.Coins{{Denom: "utest", Amount: 100}})
	assertPanic(t, revive(func() { FundBook(cross(cur), book) }), errPaymentDenom)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500)))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/fundingcaller"))
	assertPanic(t, revive(func() { FundBook(cross(cur), book) }), errDirectCall)

	testing.SetRealm(testing.NewUserRealm(testSponsor))
	FundBook(cross(cur), book)
	assertPanic(t, revive(func() { RefundSponsor(cross(cur), book) }), errRejectCoins)
	testing.SetOriginSend(nil)
	assertPanic(t, revive(func() { RefundSponsor(cross(cur), book) }), errRefundUnavailable)
	report := Submit(cross(cur), book, "Section 1", "A sponsored report.")
	testing.SetRealm(testing.NewUserRealm(testOwner))
	assertPanic(t, revive(func() { Withdraw(cross(cur), book, 1) }), errWithdraw)
	SetBookOpen(cross(cur), book, false)
	assertPanic(t, revive(func() { Accept(cross(cur), report, "") }), errClosedAccept)
	assertPanic(t, revive(func() { SetBookOpen(cross(cur), book, true) }), errSponsorRefundsPending)
	assertPanic(t, revive(func() { RefundSponsor(cross(cur), book) }), errNoSponsorFunds)

	testing.SetRealm(testing.NewUserRealm(testReader))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	assertPanic(t, revive(func() { FundBook(cross(cur), book) }), errClosedSponsor)
	assertPanic(t, revive(func() { SettleOwed(cross(cur), book) }), errRejectCoins)
	testing.SetOriginSend(nil)
	if SponsorBalance(book, testSponsor) != 500 {
		t.Fatal("a blocked action changed the sponsor balance")
	}
}

func TestCountersSurviveRemovals(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	first := CreateBook(cross(cur), "First book", "First edition", testLink, 0)
	second := CreateBook(cross(cur), "Second book", "First edition", testLink, 0)
	books.Remove(idKey(first))
	third := CreateBook(cross(cur), "Third book", "First edition", testLink, 0)
	if third != second+1 {
		t.Fatalf("book ID %d did not advance from %d", third, second)
	}
	a := Submit(cross(cur), third, "Section A", "A correction.")
	b := Submit(cross(cur), third, "Section B", "Another correction.")
	errataByID.Remove(idKey(a))
	c := Submit(cross(cur), third, "Section C", "A third correction.")
	if c != b+1 {
		t.Fatalf("report ID %d did not advance from %d", c, b)
	}
}

func TestBoundedLists(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	book := CreateBook(cross(cur), "Pagination", "First edition", testLink, 0)
	for i := 0; i < maxListLimit+1; i++ {
		CreateBook(cross(cur), "Book "+strconv.Itoa(i), "First edition", testLink, 0)
		id := Submit(cross(cur), book, "Location "+strconv.Itoa(i), "A correction.")
		Accept(cross(cur), id, "")
	}
	if got := len(ListBooks(0, int(maxAmount))); got != 50 {
		t.Fatalf("book limit = %d, want 50", got)
	}
	if len(ListBooks(books.Size(), 1)) != 0 || len(ListBooks(0, 0)) != 0 || len(ListBooks(-1, 1)) != 0 {
		t.Fatal("book list accepted an out-of-range offset or empty limit")
	}
	if got := len(ListErrata(book, Accepted, 0, int(maxAmount))); got != 50 {
		t.Fatalf("report limit = %d, want 50", got)
	}
	if len(ListErrata(book, Accepted, 52, 5)) != 0 || len(ListErrata(book, Accepted, 0, 0)) != 0 ||
		len(ListErrata(book, Accepted, -1, 1)) != 0 || len(ListErrata(book, "unknown", 0, 1)) != 0 {
		t.Fatal("report list accepted invalid pagination or a status")
	}
	if got := len(AcceptedEntries(book)); got != 50 {
		t.Fatalf("default entries = %d, want 50", got)
	}
	last := AcceptedEntriesPage(book, 50, 200)
	if len(last) != 1 || last[0].Location != "Location 50" {
		t.Fatalf("unexpected last page: %+v", last)
	}
}

func TestModeratedRendering(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testOwner))
	book := CreateBook(cross(cur), "Moderation", "First edition", testLink, 0)
	acceptedText := "Accepted marker | <b>safe</b>"
	rejectedText := "Rejected marker | <script>unsafe</script>"
	accepted := Submit(cross(cur), book, "Section A", acceptedText)
	rejected := Submit(cross(cur), book, "Section B", rejectedText)
	Accept(cross(cur), accepted, "")
	Reject(cross(cur), rejected, "Rejected note marker")
	bookPath := "book/" + strconv.Itoa(book)
	bookPage := Render(bookPath)
	for _, want := range []string{"Owner funds:", "Sponsor funds:", "(locked)", "Owed:", "The owner decides", sanitize.TableCell(acceptedText)} {
		if !strings.Contains(bookPage, want) {
			t.Errorf("book page missing %q", want)
		}
	}
	for _, route := range []string{
		"", bookPath, bookPath + "/pending",
		"erratum/" + strconv.Itoa(rejected), "finder/" + testOwner.String() + "/unpaid",
	} {
		got := Render(route)
		if strings.Contains(got, "Rejected marker") || strings.Contains(got, "Rejected note marker") {
			t.Errorf("rejected correction or note leaked into %q", route)
		}
	}
	all := Render(bookPath + "/all")
	if !strings.Contains(all, sanitize.TableCell(rejectedText)) ||
		!strings.Contains(all, "Rejected note marker") || strings.Contains(all, "<script>") {
		t.Fatalf("all reports should escape and show the rejected correction: %s", all)
	}
}

func TestPublicReportNoticeOnHomeAndBook(cur realm, t *testing.T) {
	const notice = "Reports are public and permanent on-chain."
	testing.SetRealm(testing.NewUserRealm(testOwner))
	book := CreateBook(cross(cur), "Public report notice", "First edition", testLink, 0)

	if !strings.Contains(Render(""), notice+"\n\nUse the Actions tab") {
		t.Error("home page must show the notice directly before the report instructions")
	}
	if !strings.Contains(Render("book/"+strconv.Itoa(book)), notice+"\n\n[Pending (") {
		t.Error("book page must show the notice directly before the pending report link")
	}
}
