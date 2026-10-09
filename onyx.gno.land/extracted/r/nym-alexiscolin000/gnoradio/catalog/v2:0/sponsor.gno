package catalog

import (
	"chain"
	"chain/banker"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Sponsored picks: a verified artist funds a budget that refunds the cost of
// a listener's pick of their track once it has aired in full: the pick's fee
// at the app's 80M gas limit (0.08 GNOT) and its ~1,200-byte deposit (0.12
// GNOT), plus the collect's fee at 40M (0.04 GNOT), less the ~500 bytes of
// deposit the collect frees (0.05 GNOT): about 0.19 GNOT (radio/v1 gas
// filetests). It is a refund, not paid listening: the payout stays near the
// pick cost so throwaway wallets gain nothing by farming it, and the radio
// adds airtime and reputation rules (radio/sponsor.gno). Residual,
// accepted: a script that sets tight gas limits pays less than the 0.2 GNOT
// refund and keeps about 0.05 to 0.1 GNOT a pick, within the quotas (three
// sponsored picks a wallet a day, one per artist, and the budget's daily
// limit, defaultPerDay unless the artist sets one), so a budget drains no
// faster than its daily limit.
//
// The coins sit in the data realm's vault, account "catalog/<P(artist)>",
// never in this realm. The radio reserves the payout when the pick is queued
// (a vault hold); the hold is paid when the pick has aired, released if the
// slot is dropped, and lapses by itself claimDays after the slot ends. The
// funder withdraws the rest at any time with data.VaultWithdraw, whatever
// this realm does: paused, replaced or retired. This realm only keeps the
// artist's settings and stats (catalog/budgets).
//
// A budget has a funding generation, bumped when another wallet funds it
// (the previous funder is refunded, holds included). A reservation carries
// the generation it was made in, and pays or releases only in that one: the
// vault pools an artist's holds per day, so a reservation of an earlier
// funding is never paid from (nor released into) a later listener's hold,
// even when the budget went back to the same funder.

const (
	defaultPickPay = 200_000 // ugnot per aired sponsored pick, 0.2 GNOT: the pick and its collect (above)
	minPickPay     = 10_000
	maxPickPay     = 500_000 // room for dearer gas, still a refund, never a wage
	maxPickPerDay  = 100     // the artist's own daily limit
	defaultPerDay  = 10      // the daily limit unless the artist sets one (0 = this default): a farming script drains a budget slowly
	walletPicksDay = 3       // sponsored picks per listener per UTC day, one per artist
	claimDays      = 7       // a reservation lapses this long after the slot ends
	daySecs        = 24 * 3600
)

// dataPath is the data realm: its address holds the vault's coins.
const dataPath = "gno.land/r/nym-alexiscolin000/gnoradio/data"

type budget struct {
	Pay    int64 // per aired sponsored pick, 0 = paused
	PerDay int   // sponsored picks a day (stored 0 reads as defaultPerDay)
	Day    int64 // UTC day of Today
	Today  int
	Funded int64
	Paid   int64
	Picks  int
	Gen    int // funding generation (see above)
}

// acct is an artist's vault account.
func acct(artistID int) string { return "catalog/" + store.Pad(artistID) }

func getBudget(t *tx, artistID int) (budget, bool) {
	rec, ok := t.get(cBudgets, store.Pad(artistID))
	if !ok {
		return budget{}, false
	}
	f := store.Fields(rec)
	b := budget{Pay: text.MustAtoi64(f[0]), PerDay: text.MustAtoi(f[1]), Day: text.MustAtoi64(f[2]), Today: text.MustAtoi(f[3]), Funded: text.MustAtoi64(f[4]),
		Paid: text.MustAtoi64(f[5]), Picks: text.MustAtoi(f[6]), Gen: text.MustAtoi(store.Field(rec, 7))}
	if b.PerDay == 0 {
		b.PerDay = defaultPerDay
	}
	return b, true
}

func putBudget(t *tx, artistID int, b budget) {
	t.set(cBudgets, store.Pad(artistID), store.Rec(text.Itoa64(b.Pay), text.Itoa(b.PerDay), text.Itoa64(b.Day), text.Itoa(b.Today),
		text.Itoa64(b.Funded), text.Itoa64(b.Paid), text.Itoa(b.Picks), text.Itoa(b.Gen)))
}

func today() int64 { return now() / daySecs }

// lapseDay is the last UTC day a pick ending at end can be paid.
func lapseDay(end int64) int64 { return (end + claimDays*daySecs) / daySecs }

// FundPromo adds the attached ugnot to the caller's sponsored-pick budget in
// the vault. A new budget pays defaultPickPay per aired pick (SetPromoPay
// changes it). If the profile changed hands since the last funding, the
// previous funder gets their whole balance back first, reservations included,
// and the budget starts a new funding generation. The caller's budget must
// then hold at least one refund, or no pick could ever use it.
func FundPromo(cur realm) {
	caller := userCaller(cur)
	amt := paid()
	if amt < minTip || amt > maxTip {
		panic("catalog: a promo budget takes 0.1 to 1000000 GNOT")
	}
	t := rd()
	id, arec := ownArtist(t, caller)
	if store.Field(arec, aVerified) == "" {
		panic("catalog: verify your profile first")
	}
	b, ok := getBudget(t, id)
	if !ok {
		b.Pay = defaultPickPay
	}
	b.Funded += amt
	ac := acct(id)
	funder, bal, _ := data.VaultInfo(ac)
	own := amt // what the caller will have in the budget
	if funder == caller {
		own += bal
	}
	if b.Pay > 0 && own < b.Pay {
		panic("catalog: fund at least one pick's refund (" + text.Itoa64(b.Pay) + " ugnot)")
	}
	if funder != caller && funder != "" {
		b.Gen++ // every reservation of the previous funding is void
		if bal > 0 {
			data.VaultRefund(cross(cur), ac)
			emitEvent("PromoWithdrawn", "artist", text.Itoa(id), "to", funder.String(), "amount", text.Itoa64(bal))
		}
	}
	putBudget(t, id, b)
	// The coins go to the vault before data counts them (data checks it).
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), chain.PackageAddress(dataPath), chain.Coins{{Denom: denom, Amount: amt}})
	data.VaultCredit(cross(cur), ac, caller, amt)
	save(cur, t)
	_, bal, _ = data.VaultInfo(ac)
	emitEvent("PromoFunded", "artist", text.Itoa(id), "by", caller.String(), "amount", text.Itoa64(amt), "balance", text.Itoa64(bal))
}

// SetPromoPay sets what each aired sponsored pick of the caller's tracks
// refunds (10 000..500 000 ugnot, 0 pauses) and the daily limit (1 to 100,
// 0 = the default, 10).
func SetPromoPay(cur realm, ugnotPerPick int64, perDay int) {
	caller := userCaller(cur)
	noPayment()
	if ugnotPerPick != 0 && (ugnotPerPick < minPickPay || ugnotPerPick > maxPickPay) {
		panic("catalog: a sponsored pick refunds 0.01 to 0.5 GNOT (0 pauses)")
	}
	if perDay < 0 || perDay > maxPickPerDay {
		panic("catalog: the daily limit is 1 to 100 picks (0: the default, 10)")
	}
	t := rd()
	id, _ := ownArtist(t, caller)
	b, _ := getBudget(t, id)
	b.Pay, b.PerDay = ugnotPerPick, perDay
	putBudget(t, id, b)
	save(cur, t)
	emitEvent("PromoPay", "artist", text.Itoa(id), "pay", text.Itoa64(ugnotPerPick), "perDay", text.Itoa(perDay))
}

// PromoReserve reserves the refund of a sponsored pick of trackID by picker
// whose slot ends at end. Only the radio realm may call it (radio.QueueSponsored);
// it panics with the reason when the pick cannot be sponsored. It returns
// the amount reserved and the budget's funding generation, which the radio
// passes back to PromoClaim, PromoClaimable and PromoRelease.
func PromoReserve(cur realm, trackID int, picker address, end int64) (int64, int) {
	onlyRadio(cur)
	t := rd()
	tr := mustTrack(t, trackID)
	a := getArtist(t, tr.Artist)
	b, _ := getBudget(t, a.ID)
	funder, _, free := data.VaultInfo(acct(a.ID))
	if a.Hidden || !a.Verified || a.Owner == "" || funder != a.Owner || b.Pay == 0 {
		panic("catalog: this artist does not sponsor picks right now")
	}
	own := picker == a.Owner || !role.Canonical(picker) || data.IsGnoRadio(picker)
	for _, s := range tr.Splits {
		own = own || s.To == picker
	}
	if own {
		panic("catalog: the artist and collaborators cannot take a sponsored pick")
	}
	day := today()
	if b.Day != day {
		b.Day, b.Today = day, 0
	}
	if b.PerDay > 0 && b.Today >= b.PerDay {
		panic("catalog: this artist's sponsored picks for today are taken, pick it normally")
	}
	if free < b.Pay {
		panic("catalog: this artist's promo budget is empty, pick it normally")
	}
	wd := t.val(cWalletDay, picker.String())
	d, list, _ := strings.Cut(wd, "|")
	if text.Atoi64(d) != day {
		list = ""
	}
	if strings.Contains(","+list, ","+text.Itoa(a.ID)+",") {
		panic("catalog: one sponsored pick per artist a day, pick it normally")
	}
	if strings.Count(list, ",") >= walletPicksDay {
		panic("catalog: three sponsored picks a day, pick normally")
	}
	t.set(cWalletDay, picker.String(), text.Itoa64(day)+"|"+list+text.Itoa(a.ID)+",")
	b.Today++
	putBudget(t, a.ID, b)
	data.VaultHold(cross(cur), acct(a.ID), b.Pay, lapseDay(end))
	save(cur, t)
	emitEvent("PromoReserved", "artist", text.Itoa(a.ID), "track", text.Itoa(trackID), "picker", picker.String(), "amount", text.Itoa64(b.Pay))
	return b.Pay, b.Gen
}

// PromoClaim pays picker a reservation of funding generation gen once their
// sponsored pick ending at end has aired; the radio realm checks the slot. A
// lapsed or cancelled reservation (the budget was refunded since) pays nothing.
func PromoClaim(cur realm, trackID int, picker address, end, amount int64, gen int) {
	onlyRadio(cur)
	t := rd()
	artistID, _, _, _, _ := brief(t, trackID)
	e := lapseDay(end)
	if data.VaultDay() > e { // the vault's clock: a pause never makes a refund lapse
		panic("catalog: this sponsored pick was not collected within 7 days")
	}
	b, _ := getBudget(t, artistID)
	if amount <= 0 || b.Gen != gen || data.VaultHeld(acct(artistID), e) < amount {
		panic("catalog: this sponsorship was cancelled")
	}
	b.Paid += amount
	b.Picks++
	putBudget(t, artistID, b)
	data.VaultPay(cross(cur), acct(artistID), picker, amount, e)
	save(cur, t)
	emitEvent("PromoPaid", "artist", text.Itoa(artistID), "track", text.Itoa(trackID), "to", picker.String(), "amount", text.Itoa64(amount))
}

// PromoClaimable reports whether PromoClaim would pay a sponsored pick's
// refund: reserved for end in generation gen, neither lapsed nor cancelled.
func PromoClaimable(trackID int, end, amount int64, gen int) bool {
	t := rd()
	artistID, _, _, _, _ := brief(t, trackID)
	e := lapseDay(end)
	b, _ := getBudget(t, artistID)
	return data.VaultDay() <= e && amount > 0 && b.Gen == gen && data.VaultHeld(acct(artistID), e) >= amount
}

// PromoRelease returns a reservation to its budget: the slot was dropped or
// cut before it aired in full. A reservation of an earlier funding
// generation than gen's budget was refunded with it: nothing to release. A
// pick that never aired, reserved at reserved (unix; 0 when it partly aired),
// also gives back the daily counts it took, the artist's and picker's, if
// that was today. Radio realm only.
func PromoRelease(cur realm, trackID int, picker address, end, amount, reserved int64, gen int) {
	onlyRadio(cur)
	t := rd()
	artistID, _, _, _, _ := brief(t, trackID)
	b, _ := getBudget(t, artistID)
	if amount > 0 && b.Gen == gen {
		// lapsed or cancelled already: less, or nothing
		if amount = data.VaultRelease(cross(cur), acct(artistID), amount, lapseDay(end)); amount > 0 {
			emitEvent("PromoReleased", "artist", text.Itoa(artistID), "track", text.Itoa(trackID), "amount", text.Itoa64(amount))
		}
	}
	day := today()
	if reserved <= 0 || reserved/daySecs != day {
		return
	}
	if b.Day == day && b.Today > 0 {
		b.Today--
		putBudget(t, artistID, b)
	}
	wd := t.val(cWalletDay, picker.String())
	if d, list, _ := strings.Cut(wd, "|"); text.Atoi64(d) == day {
		t.set(cWalletDay, picker.String(), d+"|"+strings.Replace(","+list, ","+text.Itoa(artistID)+",", ",", 1)[1:])
	}
	save(cur, t)
}

// PromoOffer is what a sponsored pick of the artist's tracks refunds right
// now (0: none). Picker-specific limits are checked when picking.
func PromoOffer(artistID int) int64 {
	t := rd()
	return offer(t, getArtist(t, artistID))
}

func offer(t *tx, a *Artist) int64 {
	if a == nil {
		return 0
	}
	if a.Hidden || !a.Verified || a.Owner == "" {
		return 0
	}
	b, ok := getBudget(t, a.ID)
	if !ok || b.Pay == 0 || b.PerDay > 0 && b.Day == today() && b.Today >= b.PerDay {
		return 0
	}
	if funder, _, free := data.VaultInfo(acct(a.ID)); funder != a.Owner || free < b.Pay {
		return 0
	}
	return b.Pay
}

// PromoJSON is an artist's sponsored-pick budget:
// {"artist","funder","balance","reserved","free","pay","perDay","today","funded","paid","picks","offer"}.
// The funder withdraws "free" with data.VaultWithdraw(acct) where acct is
// "catalog/" and the artist id on 8 digits.
func PromoJSON(artistID int) string {
	t := rd()
	b, _ := getBudget(t, artistID)
	funder, bal, free := data.VaultInfo(acct(artistID))
	if b.Day != today() {
		b.Today = 0
	}
	return `{"artist":` + text.Itoa(artistID) + `,"funder":` + text.Str(funder.String()) + `,"balance":` + text.Itoa64(bal) +
		`,"reserved":` + text.Itoa64(bal-free) + `,"free":` + text.Itoa64(free) + `,"pay":` + text.Itoa64(b.Pay) + `,"perDay":` + text.Itoa(b.PerDay) +
		`,"today":` + text.Itoa(b.Today) + `,"funded":` + text.Itoa64(b.Funded) + `,"paid":` + text.Itoa64(b.Paid) + `,"picks":` + text.Itoa(b.Picks) +
		`,"offer":` + text.Itoa64(offer(t, getArtist(t, artistID))) + `}`
}
