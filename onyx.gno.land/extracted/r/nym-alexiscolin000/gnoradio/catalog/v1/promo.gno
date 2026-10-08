package catalog

import (
	"gno.land/p/nym-alexiscolin000/gnoradio/store/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// Promo share: an artist lets a part of each tip go to the listeners who
// brought the tipper, the one who picked the track on the radio and the one
// whose link they followed. It is opt-in: 0% until the artist sets it
// (0..20%), and the tipper sees it before signing. A tipper never pays it to
// themselves: not as the picker, not as the referrer, and not to a
// referrer they name for a track they picked (social.gno, tip). The radio realm alone knows who picked what
// is on air, so the shared tips arrive through RadioTip, which only the
// current radio writer of the data realm may call; it never takes a picker
// from the client.

const (
	defaultPromoPct = 0
	maxPromoPct     = 20
)

// SetPromoShare sets the percent of each tip on the caller's tracks that goes
// to the picker and the referrer (0..20).
func SetPromoShare(cur realm, pct int) {
	caller := userCaller(cur)
	noPayment()
	if pct < 0 || pct > maxPromoPct {
		panic("catalog: the promo share is between 0 and 20%")
	}
	t := rd()
	id, _ := ownArtist(t, caller)
	t.set(cPromo, store.Pad(id), text.Itoa(pct))
	save(cur, t)
	emitEvent("PromoShare", "artist", text.Itoa(id), "pct", text.Itoa(pct))
}

// PromoShare returns an artist's promo percent.
func PromoShare(artistID int) int { return promoShare(rd(), artistID) }

func promoShare(t *tx, artistID int) int {
	if v, ok := t.get(cPromo, store.Pad(artistID)); ok {
		return text.Atoi(v)
	}
	return defaultPromoPct
}

// RadioTip pays a tip the radio realm received for the listener tipper
// (radio.TipOnAir): the radio has already forwarded total ugnot to this realm
// and names the picker of the slot on air. Only the radio writer may call it.
// It returns what the picker and the referrer received.
func RadioTip(cur realm, trackID, supportPct int, tipper, picker, ref address, total int64) (toPicker, toRef int64) {
	onlyRadio(cur)
	return tip(cur, tipper, total, trackID, supportPct, picker, ref)
}

// onlyRadio admits the radio realm the data realm names as radio writer
// now, unless the radio role is paused: a paused radio moves no coins
// through the catalog either.
func onlyRadio(cur realm) {
	if cur.Previous().PkgPath() != data.Writer("radio") {
		panic("catalog: only the GnoRadio radio realm can call this")
	}
	if data.Paused("radio") {
		panic("catalog: the radio is paused")
	}
}

// promoShares splits an artist-side amount's promo share between the picker
// and the referrer still eligible ("" when not): half each, the odd ugnot to
// the picker, all of it to one alone.
func promoShares(amt int64, pct int, picker, ref address) (toPicker, toRef int64) {
	share := amt * int64(pct) / 100
	switch {
	case picker != "" && ref != "":
		toRef = share / 2
		return share - toRef, toRef
	case picker != "":
		return share, 0
	case ref != "":
		return 0, share
	}
	return 0, 0
}
