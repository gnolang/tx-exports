package admitone

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const (
	selfTestPath = "gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/admitone/v1"
	gnotU        = 1000000
)

var (
	selfAddr  = chain.PackageAddress(selfTestPath)
	organiser = testutils.TestAddress("organiser")
	ann       = testutils.TestAddress("ann")
	sam       = testutils.TestAddress("sam")
	bo        = testutils.TestAddress("bo")
	kim       = testutils.TestAddress("kim")
	lighter   = testutils.TestAddress("lighter")
)

func ugnotOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}

// sending attaches coins to the next call into this realm. The test banker
// does not move those coins by itself, so they are issued to the realm.
// Choosing the caller (testing.SetRealm) has to stay in the test function
// itself, because the test runtime ties it to the calling frame.
func sending(amount int64) {
	if amount == 0 {
		testing.SetOriginSend(nil)
		return
	}
	coins := chain.Coins{{denom, amount}}
	testing.IssueCoins(selfAddr, coins)
	testing.SetOriginSend(coins)
}

// checkBooks checks, for the events a test created, that the coins this realm
// holds are exactly what it owes ticket holders, and that the ticket ledger
// agrees with the events. The test runtime empties balances between test
// functions, so each test passes only its own events.
func checkBooks(t *testing.T, ids ...uint64) {
	t.Helper()
	var owed int64
	live := 0
	for _, id := range ids {
		e := mustEvent(id)
		owed += escrow(e)
		live += e.live
		n := 0
		prefix := pad(id) + "-"
		tickets.Iterate(prefix, prefix+"~", func(_ string, _ any) bool { n++; return false })
		uassert.Equal(t, e.live, n, "every live ticket of event "+utoa(id)+" is on record")
	}
	uassert.Equal(t, owed, ugnotOf(selfAddr), "the realm holds exactly the escrow of its live tickets")
}

// in returns a start time d seconds from now.
func in(d int64) int64 { return time.Now().Unix() + d }

// The demo story: a quiz night with a capped resale, admissions at the door,
// two no-shows, and a lamplighter settling it at the end.
func TestQuizNight(cur realm, t *testing.T) {
	start := in(600)
	end := start + 3600

	testing.SetRealm(testing.NewUserRealm(organiser))
	sending(LampFee)
	id := CreateEvent(cross(cur), "Quiz night", "Teams of four, bring a pencil", start, end, 1*gnotU, 20, 2, 1000, 2000)
	testing.SetOriginSend(nil)
	job := JobOf(id)
	uassert.NotEqual(t, uint64(0), job)
	uassert.Equal(t, LampFee, registry.Balance(job), "the organiser's fee funds the job that settles the event")
	uassert.Equal(t, end, registry.NextDue(job))

	testing.SetRealm(testing.NewUserRealm(ann))
	sending(1 * gnotU)
	a1 := Buy(cross(cur), id)
	sending(1 * gnotU)
	a2 := Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.Equal(t, "1-1", a1)
	uassert.Equal(t, ann, OwnerOf(a2))
	bal, _ := Token().BalanceOf(ann)
	uassert.Equal(t, int64(2), bal, "tickets are GRC721 tokens")
	checkBooks(t, id)

	testing.SetRealm(testing.NewUserRealm(sam))
	sending(1 * gnotU)
	s1 := Buy(cross(cur), id)
	sending(1 * gnotU)
	s2 := Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.Equal(t, "one address may hold at most 2 tickets for this event", buyRefusal(mustEvent(id), sam, time.Now().Unix()))
	uassert.AbortsWithMessage(t, cur, "list at 0 to 1100000 ugnot: face value plus at most 10%", func() { List(cross(cur), s1, 5*gnotU) })
	List(cross(cur), s1, 1100000)
	uassert.True(t, strings.Contains(Render("event/1"), "## Resale desk"))
	uassert.Equal(t, "the listing opens to buyers in 60s", buyListedRefusal(mustTicket(s1), bo, time.Now().Unix()),
		"a listing cannot be bought in the transaction that posts it")
	testing.SkipHeights(13)

	testing.SetRealm(testing.NewUserRealm(bo))
	samBefore := ugnotOf(sam)
	uassert.Equal(t, "send exactly 1700000 ugnot", payRefusal(chain.Coins{{denom, 1100000}}, 1100000+ResaleDeposit))
	sending(1100000 + ResaleDeposit)
	BuyListed(cross(cur), s1)
	testing.SetOriginSend(nil)
	uassert.Equal(t, bo, OwnerOf(s1))
	uassert.Equal(t, samBefore+1100000+ResaleDeposit, ugnotOf(sam), "the seller gets the price and the deposit allowance")
	checkBooks(t, id)

	// The doors are not open yet.
	testing.SetRealm(testing.NewUserRealm(ann))
	uassert.AbortsWithMessage(t, cur, "doors open at "+when(start), func() { Admit(cross(cur), a1) })
	testing.SkipHeights(121) // 605 s: doors open

	orgBefore := ugnotOf(organiser)
	Admit(cross(cur), a1)
	uassert.Equal(t, orgBefore+1*gnotU, ugnotOf(organiser), "walking in pays the organiser")
	uassert.True(t, IsAdmitted(a1))
	uassert.True(t, Attended(id, ann))
	uassert.AbortsWithMessage(t, cur, "already admitted", func() { Admit(cross(cur), a1) })
	uassert.AbortsWithMessage(t, cur, "an admitted ticket cannot be resold", func() { List(cross(cur), a1, 0) })
	uassert.True(t, strings.Contains(Render("ticket/"+a1), "ADMITTED"))

	testing.SetRealm(testing.NewUserRealm(sam))
	uassert.AbortsWithMessage(t, cur, "only the holder can do this", func() { Admit(cross(cur), a2) })
	testing.SetRealm(testing.NewUserRealm(bo))
	Admit(cross(cur), s1)
	checkBooks(t, id)

	// a2 and s2 never come. Nobody can refund before the end.
	testing.SetRealm(testing.NewUserRealm(ann))
	uassert.AbortsWithMessage(t, cur, "refunds open when the event is cancelled or over", func() { Refund(cross(cur), a2) })

	testing.SkipHeights(721) // past the end
	uassert.True(t, registry.IsDue(job))
	orgBefore = ugnotOf(organiser)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), job)
	uassert.Equal(t, orgBefore+2*200000, ugnotOf(organiser), "settling pays the no-show fee of each unused ticket")
	uassert.AbortsWithMessage(t, cur, "event 1 is already settled", func() { Settle(cross(cur), id) })
	checkBooks(t, id)

	testing.SetRealm(testing.NewUserRealm(ann))
	annBefore := ugnotOf(ann)
	Refund(cross(cur), a2)
	uassert.Equal(t, annBefore+800000, ugnotOf(ann), "a no-show gets the price minus the fee")
	uassert.AbortsWithMessage(t, cur, "an admitted ticket has been used", func() { Refund(cross(cur), a1) })
	uassert.AbortsWithMessage(t, cur, `unknown ticket "1-2"`, func() { Refund(cross(cur), a2) })
	testing.SetRealm(testing.NewUserRealm(sam))
	Refund(cross(cur), s2)
	checkBooks(t, id)
	uassert.Equal(t, int64(0), ugnotOf(selfAddr))
	supply := Token().TotalSupply()
	uassert.Equal(t, int64(2), supply, "refunded tickets are burned; the admitted ones stay as stamps")

	// bo throws his stamp away to take back its storage deposit.
	testing.SetRealm(testing.NewUserRealm(bo))
	Discard(cross(cur), s1)
	uassert.Equal(t, int64(1), Token().TotalSupply())
	uassert.False(t, Attended(id, bo))
	uassert.True(t, strings.Contains(Render("event/1"), "| At the door | 2 admitted |"), "the door count keeps discarded tickets")
	checkBooks(t, id)

	testing.SetRealm(testing.NewUserRealm(ann))
	uassert.AbortsWithMessage(t, cur, "only the organiser can reclaim the job's deposit", func() { Reclaim(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(organiser))
	Reclaim(cross(cur), id)
	uassert.False(t, registry.Exists(job))
	uassert.AbortsWithMessage(t, cur, "there is no job to reclaim", func() { Reclaim(cross(cur), id) })
}

func TestCancelRefundsEverything(cur realm, t *testing.T) {
	start := in(3600)
	testing.SetRealm(testing.NewUserRealm(organiser))
	sending(LampFee)
	id := CreateEvent(cross(cur), "Rained off", "", start, start+600, 500000, 10, 3, 0, 5000)
	testing.SetOriginSend(nil)
	job := JobOf(id)

	testing.SetRealm(testing.NewUserRealm(kim))
	sending(500000)
	k1 := Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the organiser can cancel the event", func() { Cancel(cross(cur), id) })

	orgBefore := ugnotOf(organiser)
	testing.SetRealm(testing.NewUserRealm(organiser))
	Cancel(cross(cur), id)
	uassert.False(t, registry.Exists(job), "cancelling the event cancels its job")
	uassert.Equal(t, orgBefore+LampFee, ugnotOf(organiser), "and the job's unspent fee goes back to the organiser")
	uassert.AbortsWithMessage(t, cur, "the event is already cancelled", func() { Cancel(cross(cur), id) })
	checkBooks(t, id)

	testing.SetRealm(testing.NewUserRealm(bo))
	uassert.Equal(t, "the event is cancelled", buyRefusal(mustEvent(id), bo, time.Now().Unix()))
	uassert.AbortsWithMessage(t, cur, "event 2 was cancelled", func() { Settle(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(kim))
	kimBefore := ugnotOf(kim)
	Refund(cross(cur), k1)
	uassert.Equal(t, kimBefore+500000, ugnotOf(kim), "a cancelled event refunds the full price, no-show fee or not")
	checkBooks(t, id)
	uassert.True(t, strings.Contains(Render("event/"+utoa(id)), "This event was cancelled"))
}

// A free event is an RSVP list with an attendance stamp.
func TestFreeEvent(cur realm, t *testing.T) {
	start := in(60)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id := CreateEvent(cross(cur), "Judges' table", "Free: buy, then admit yourself", start, start+7200, 0, 3, 1, 0, 0)
	uassert.Equal(t, uint64(0), JobOf(id), "no fee sent, no job")

	testing.SetRealm(testing.NewUserRealm(kim))
	uassert.Equal(t, "send nothing: it is free", payRefusal(chain.Coins{{denom, 1}}, 0))
	k := Buy(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "list at 0 to 0 ugnot: face value plus at most 0%", func() { List(cross(cur), k, 1) })

	testing.SetRealm(testing.NewUserRealm(ann))
	annTicket := Buy(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(bo))
	Buy(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(sam))
	uassert.Equal(t, "sold out", buyRefusal(mustEvent(id), sam, time.Now().Unix()))

	testing.SkipHeights(13)
	testing.SetRealm(testing.NewUserRealm(kim))
	uassert.False(t, Attended(id, kim))
	Admit(cross(cur), k)
	uassert.True(t, Attended(id, kim))
	uassert.False(t, Attended(id, ann))
	uassert.AbortsWithMessage(t, cur, "keep it until the event is over", func() { Discard(cross(cur), k) })
	testing.SetRealm(testing.NewUserRealm(ann))
	uassert.AbortsWithMessage(t, cur, "only an admitted ticket can be discarded; refund an unused one", func() { Discard(cross(cur), annTicket) })
	checkBooks(t, id)

	testing.SkipHeights(1500)
	testing.SetRealm(testing.NewUserRealm(lighter))
	Settle(cross(cur), id)
	checkBooks(t, id)
}

// Without a job, the first refund after the end pays that ticket's fee to the
// organiser itself, and Settle pays only for the rest.
func TestRefundBeforeSettle(cur realm, t *testing.T) {
	start := in(60)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id := CreateEvent(cross(cur), "Lecture", "", start, start+60, 300000, 5, 5, 0, 3333)

	testing.SetRealm(testing.NewUserRealm(ann))
	sending(300000)
	x := Buy(cross(cur), id)
	sending(300000)
	Buy(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SkipHeights(30) // past the end
	fee := int64(300000 * 3333 / 10000)
	orgBefore, annBefore := ugnotOf(organiser), ugnotOf(ann)
	Refund(cross(cur), x)
	uassert.Equal(t, orgBefore+fee, ugnotOf(organiser))
	uassert.Equal(t, annBefore+300000-fee, ugnotOf(ann))
	checkBooks(t, id)

	orgBefore = ugnotOf(organiser)
	testing.SetRealm(testing.NewUserRealm(lighter))
	Settle(cross(cur), id)
	uassert.Equal(t, orgBefore+fee, ugnotOf(organiser), "settle pays only the ticket still held")
	checkBooks(t, id)

	testing.SetRealm(testing.NewUserRealm(organiser))
	uassert.AbortsWithMessage(t, cur, "there is no job to reclaim", func() { Reclaim(cross(cur), id) })
}

func TestResaleRules(cur realm, t *testing.T) {
	start := in(600)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id := CreateEvent(cross(cur), "Gig", "", start, start+600, 200000, 3, 1, 2500, 0)

	testing.SetRealm(testing.NewUserRealm(ann))
	sending(200000)
	a := Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "the ticket is not listed", func() { Unlist(cross(cur), a) })
	List(cross(cur), a, 250000)
	uassert.Equal(t, "the listing opens to buyers in 60s", buyListedRefusal(mustTicket(a), bo, time.Now().Unix()))
	testing.SkipHeights(13)
	uassert.Equal(t, "this is already your ticket", buyListedRefusal(mustTicket(a), ann, time.Now().Unix()))
	testing.SetRealm(testing.NewUserRealm(bo))
	uassert.AbortsWithMessage(t, cur, "only the holder can do this", func() { List(cross(cur), a, 0) })
	uassert.AbortsWithMessage(t, cur, "only the holder can do this", func() { Unlist(cross(cur), a) })
	uassert.AbortsWithMessage(t, cur, "only the holder can do this", func() { Refund(cross(cur), a) })
	uassert.AbortsWithMessage(t, cur, "only the holder can do this", func() { Discard(cross(cur), a) })
	testing.SetRealm(testing.NewUserRealm(ann))
	Unlist(cross(cur), a)

	testing.SetRealm(testing.NewUserRealm(bo))
	uassert.Equal(t, "the ticket is not for sale", buyListedRefusal(mustTicket(a), bo, time.Now().Unix()))

	// bo already holds his one ticket, so he cannot take ann's.
	sending(200000)
	Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(ann))
	List(cross(cur), a, 180000)
	testing.SkipHeights(13)
	testing.SetRealm(testing.NewUserRealm(bo))
	uassert.Equal(t, "one address may hold at most 1 tickets for this event", buyListedRefusal(mustTicket(a), bo, time.Now().Unix()))
	testing.SetRealm(testing.NewUserRealm(kim))
	sending(180000 + ResaleDeposit)
	BuyListed(cross(cur), a)
	testing.SetOriginSend(nil)
	uassert.Equal(t, kim, OwnerOf(a))
	uassert.Equal(t, 0, held(mustEvent(id), ann))
	uassert.True(t, strings.Contains(Render("u/"+kim.String()), a))
	uassert.False(t, strings.Contains(Render("u/"+ann.String()), "| ["+a+"]"))

	// Nothing to resell once it is over.
	testing.SkipHeights(250)
	uassert.AbortsWithMessage(t, cur, "the event is over", func() { List(cross(cur), a, 0) })
	uassert.AbortsWithMessage(t, cur, "the event is over", func() { Admit(cross(cur), a) })
	testing.SetRealm(testing.NewUserRealm(lighter))
	Settle(cross(cur), id)
	checkBooks(t, id)
}

func TestCreateRules(cur realm, t *testing.T) {
	n := time.Now().Unix()
	s := n + 600
	cases := []struct {
		msg string
		got string
	}{
		{"name must be 1 to 60 bytes of printable text", checkEvent("", "", s, s+600, 0, 1, 1, 0, 0, n)},
		{"name must be 1 to 60 bytes of printable text", checkEvent("a\nb", "", s, s+600, 0, 1, 1, 0, 0, n)},
		{"name must be 1 to 60 bytes of printable text", checkEvent("   ", "", s, s+600, 0, 1, 1, 0, 0, n)},
		{"name must be 1 to 60 bytes of printable text", checkEvent("\u200b", "", s, s+600, 0, 1, 1, 0, 0, n)},
		{"name must be 1 to 60 bytes of printable text", checkEvent("a\u0085b", "", s, s+600, 0, 1, 1, 0, 0, n)},
		{"details must be at most 280 bytes of printable text", checkEvent("x", "  ", s, s+600, 0, 1, 1, 0, 0, n)},
		{"start must be between now and a year from now", checkEvent("x", "", s-1200, s, 0, 1, 1, 0, 0, n)},
		{"an event lasts 1 minute to 90 days", checkEvent("x", "", s, s+59, 0, 1, 1, 0, 0, n)},
		{"price must be 0 to 1000000000000 ugnot", checkEvent("x", "", s, s+600, -1, 1, 1, 0, 0, n)},
		{"capacity must be 1 to 1000", checkEvent("x", "", s, s+600, 0, 1001, 1, 0, 0, n)},
		{"maxPerAddr must be 1 to the capacity", checkEvent("x", "", s, s+600, 0, 5, 6, 0, 0, n)},
		{"markupBps must be 0 to 5000", checkEvent("x", "", s, s+600, 0, 5, 1, 5001, 0, n)},
		{"noShowBps must be 0 to 10000", checkEvent("x", "", s, s+600, 0, 5, 1, 0, 10001, n)},
		{"", checkEvent("x", "", s, s+600, 0, 5, 1, 0, 0, n)},
	}
	for _, c := range cases {
		uassert.Equal(t, c.msg, c.got)
	}
	_, msg := fundRefusal(chain.Coins{{denom, LampFee + 1}})
	uassert.Equal(t, "send nothing, or exactly 50000 ugnot to have a Lamplighter job settle the event", msg)
	withJob, msg := fundRefusal(chain.Coins{{denom, LampFee}})
	uassert.True(t, withJob && msg == "")
}

// The registry runs any callback for anyone; settleJob must refuse calls that
// are not the registry running one of this realm's own jobs.
func TestSettleJobChecksItsCaller(cur realm, t *testing.T) {
	err := settleJob(cur, 1)
	uassert.Error(t, err)
	uassert.Equal(t, "only the lamplighter registry runs this", err.Error())
}

// The guards the escrow promise rests on: no cancelling once the event has
// started, and a cancelled event refunds listed tickets in full too.
func TestCancelGuards(cur realm, t *testing.T) {
	start := in(120)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id := CreateEvent(cross(cur), "Guarded", "", start, start+600, 400000, 5, 2, 0, 0)
	testing.SetRealm(testing.NewUserRealm(kim))
	sending(400000)
	k := Buy(cross(cur), id)
	testing.SetOriginSend(nil)
	List(cross(cur), k, 400000)
	testing.SetRealm(testing.NewUserRealm(organiser))
	Cancel(cross(cur), id)
	uassert.False(t, strings.Contains(Render("event/"+utoa(id)), "## Resale desk"), "a cancelled event shows no desk")
	testing.SetRealm(testing.NewUserRealm(kim))
	kimBefore := ugnotOf(kim)
	Refund(cross(cur), k)
	uassert.Equal(t, kimBefore+400000, ugnotOf(kim), "a listed ticket of a cancelled event is refunded in full")
	checkBooks(t, id)

	start = in(60)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id2 := CreateEvent(cross(cur), "Started", "", start, start+600, 0, 5, 1, 0, 0)
	testing.SkipHeights(13)
	uassert.AbortsWithMessage(t, cur, "an event that has started cannot be cancelled", func() { Cancel(cross(cur), id2) })
}

// A manual Settle before the runner must not strand the event's job: the job
// still completes, pays its runner, and leaves the queue.
func TestManualSettleLetsTheJobFinish(cur realm, t *testing.T) {
	start := in(60)
	testing.SetRealm(testing.NewUserRealm(organiser))
	sending(LampFee)
	id := CreateEvent(cross(cur), "Early bird", "", start, start+60, 0, 5, 1, 0, 0)
	testing.SetOriginSend(nil)
	job := JobOf(id)

	testing.SkipHeights(30)
	testing.SetRealm(testing.NewUserRealm(kim))
	Settle(cross(cur), id)
	lighterBefore := ugnotOf(lighter)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), job)
	uassert.Equal(t, lighterBefore+LampFee, ugnotOf(lighter), "the runner is still paid")
	uassert.True(t, registry.Done(job))
	testing.SetRealm(testing.NewUserRealm(organiser))
	Reclaim(cross(cur), id)
	uassert.False(t, registry.Exists(job))
}

func TestRenderAndFormatting(cur realm, t *testing.T) {
	start := in(60)
	testing.SetRealm(testing.NewUserRealm(organiser))
	id := CreateEvent(cross(cur), "Pages", "", start, start+600, 0, 5, 1, 0, 0)
	testing.SetRealm(testing.NewUserRealm(kim))
	k := Buy(cross(cur), id)

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Admit One"))
	uassert.True(t, strings.Contains(home, "Create an event"))
	uassert.True(t, strings.Contains(Render("event/999"), "# Not found"))
	uassert.True(t, strings.Contains(Render("ticket/9-9"), "# Ticket not found"))
	uassert.True(t, strings.Contains(Render("ticket/nonsense"), "# Ticket not found"))
	uassert.True(t, strings.Contains(Render("u/g1nobody"), "# Not an address"))
	uassert.True(t, strings.Contains(Render("u/"+kim.String()), k))
	uassert.True(t, strings.Contains(Render("ticket/"+k), "data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(Render("event/"+utoa(id)), "storage deposit"), "the buy link says what the deposit is")

	// Older events stay reachable, 20 a page.
	testing.SetRealm(testing.NewUserRealm(organiser))
	for events.Size() <= perPage {
		CreateEvent(cross(cur), "Filler", "", start, start+600, 0, 1, 1, 0, 0)
	}
	uassert.True(t, strings.Contains(Render(""), "[older]"))
	page2 := Render("page/2")
	uassert.True(t, strings.Contains(page2, "[newer]"))
	uassert.True(t, strings.Contains(page2, "| 1 | [Quiz night]"), "the first event is on the last page")
	uassert.True(t, strings.Contains(Render("page/99"), "No events on page 99"))

	uassert.Equal(t, "1.5 GNOT", gnot(1500000))
	uassert.Equal(t, "0.05 GNOT", gnot(50000))
	uassert.Equal(t, "2 GNOT", gnot(2000000))
	uassert.Equal(t, "free", priceLabel(0))
	uassert.Equal(t, "Refund (gives back its storage deposit)", refundLabel(0))
	uassert.Equal(t, "10%", bps(1000))
	uassert.Equal(t, "33.33%", bps(3333))
	uassert.Equal(t, "2.5%", bps(250))
	uassert.Equal(t, "a &lt;b&gt; &amp; &quot;c&quot;", xmlEscape(`a <b> & "c"`))
	uassert.Equal(t, "abc…", clip("abcdef", 4))
	key, ok := keyOf("12-3")
	uassert.True(t, ok)
	uassert.Equal(t, "0000000012-00003", key)
	_, ok = keyOf("12-0")
	uassert.False(t, ok)
}
