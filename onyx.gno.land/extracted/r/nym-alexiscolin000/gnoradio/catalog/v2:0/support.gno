package catalog

import (
	"chain"
	"chain/banker"
	"strings"
	"time"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// GnoRadio's own funding, always on top of what artists receive and always
// visible on-chain: direct support and the optional share added to a tip.
// Every coin is forwarded to the treasury in the same transaction.

// SupportGnoRadio sends the attached ugnot to the GnoRadio treasury.
func SupportGnoRadio(cur realm) {
	caller := userCaller(cur)
	amt := paid()
	if amt < minTip || amt > maxTip {
		panic("catalog: support is between 0.1 and 1000000 GNOT")
	}
	t := rd()
	if treasury(t) == "" {
		panic("catalog: no treasury is set, GnoRadio takes no support")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), treasury(t), chain.Coins{{Denom: denom, Amount: amt}})
	recordSupport(t, caller, amt)
	save(cur, t)
	emitEvent("Supported", "by", caller.String(), "amount", text.Itoa64(amt))
}

// SetTreasury changes where GnoRadio's support goes; "" (the default) takes none. Admin only.
func SetTreasury(cur realm, to address) {
	onlyAdmin(cur)
	if to != "" && !role.Canonical(to) { // "" switches support off
		panic("catalog: invalid address")
	}
	if data.IsGnoRadio(to) {
		panic("catalog: the treasury cannot be a GnoRadio realm")
	}
	t := rd()
	emitEvent("TreasuryChanged", "from", treasury(t).String(), "to", to.String())
	t.set(cConfig, "treasury", to.String())
	save(cur, t)
}

// SetMonthlyGoal sets the monthly support goal shown in the app (ugnot). Admin only.
func SetMonthlyGoal(cur realm, ugnot int64) {
	onlyAdmin(cur)
	if ugnot < 0 || ugnot > maxTip {
		panic("catalog: goal out of range")
	}
	t := rd()
	t.set(cConfig, "goal", text.Itoa64(ugnot))
	save(cur, t)
	emitEvent("MonthlyGoal", "ugnot", text.Itoa64(ugnot))
}

func treasury(t *tx) address { return address(t.val(cConfig, "treasury")) }

func Treasury() address { return treasury(rd()) }

// SupportInfo returns GnoRadio's public funding state for this month.
func SupportInfo() (to address, total int64, supporters int, monthTotal, goal int64) {
	t := rd()
	return treasury(t), t.count(mSupport), int(t.count(mSupporters)), text.Atoi64(t.val(cMonthly, month(now()))), text.Atoi64(t.val(cConfig, "goal"))
}

func recordSupport(t *tx, by address, amt int64) {
	t.bump(mSupport, amt)
	s, had := t.get(cSupporters, by.String())
	if !had {
		t.bump(mSupporters, 1)
	}
	total := text.Atoi64(s) + amt
	t.set(cSupporters, by.String(), text.Itoa64(total))
	t.rank(topSupport, by.String(), total, true)
	mo := month(now())
	t.set(cMonthly, mo, text.Itoa64(text.Atoi64(t.val(cMonthly, mo))+amt))
	t.activity("support", by, "0", "0", text.Itoa64(amt))
}

func month(unix int64) string { return time.Unix(unix, 0).UTC().Format("2006-01") }

// Activities returns up to limit entries, newest first.
func Activities(limit int) []Activity {
	limit = store.Limit(limit, activitySize)
	t := rd()
	head := text.Atoi(t.val(cMeta, "head"))
	out := make([]Activity, 0, limit)
	for i := 1; i <= limit; i++ {
		v := t.val(cActivity, store.Pad((head-i+activitySize)%activitySize))
		if v == "" {
			break // the ring is not full yet
		}
		f := store.Fields(v)
		out = append(out, Activity{Kind: f[0], By: address(f[1]), Track: text.Atoi(f[2]), Artist: text.Atoi(f[3]), Amount: text.Atoi64(f[4]), At: text.Atoi64(f[5])})
	}
	return out
}

// ActivityJSON returns the activity feed, newest first (limit <= 64).
func ActivityJSON(limit int) string {
	var b strings.Builder
	b.WriteString("[")
	for i, a := range Activities(limit) {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"kind":` + text.Str(a.Kind) + `,"by":` + text.Str(a.By.String()) + `,"track":` + text.Itoa(a.Track) +
			`,"artist":` + text.Itoa(a.Artist) + `,"amount":` + text.Itoa64(a.Amount) + `,"at":` + text.Itoa64(a.At) + `}`)
	}
	b.WriteString("]")
	return b.String()
}

// SupportJSON returns GnoRadio's public funding state.
func SupportJSON() string {
	to, total, supporters, mt, goal := SupportInfo()
	var b strings.Builder
	b.WriteString(`{"treasury":` + text.Str(to.String()) + `,"total":` + text.Itoa64(total) + `,"supporters":` + text.Itoa(supporters) +
		`,"month":` + text.Str(month(now())) + `,"monthTotal":` + text.Itoa64(mt) + `,"goal":` + text.Itoa64(goal) + `,"top":[`)
	for i, r := range rd().top(topSupport) {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"address":` + text.Str(r.Key) + `,"amount":` + text.Itoa64(r.Value) + `}`)
	}
	b.WriteString(`]}`)
	return b.String()
}
