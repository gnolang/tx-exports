package radio

import (
	"chain"
	"strings"

	"gno.land/p/nym-alexiscolin000/gnoradio/role/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// The radio admin (curator and moderator) is a p/role held by this realm,
// passed in two steps. Each change is mirrored to radio/config "admin", so
// the next release keeps it, and the mirror is the authority: a change the
// previous release made after this one's init counts.

// adminAddr is the admin ("" once renounced).
func adminAddr() address {
	h, ok := data.Get(cConfig, "admin")
	return role.Mirror(admin, h, ok)
}

// syncAdmin adopts the mirror when the previous release changed it after
// this one's init (during the release's delay).
func syncAdmin() {
	h, ok := data.Get(cConfig, "admin")
	admin = role.Adopt(admin, "admin", h, ok)
}

func onlyAdmin(cur realm) {
	syncAdmin()
	if admin == nil || !admin.Is(0, cur) {
		panic("radio: admin only")
	}
	noPayment()
}

// Admin is the radio admin ("" once renounced).
func Admin() address { return adminAddr() }

// PendingAdmin is the address the admin role is offered to ("" if none).
func PendingAdmin() address { return admin.Pending() }

// Ready tells the data realm that this release is on chain (see
// data.Propose). Anyone may call it.
func Ready(cur realm) {
	noPayment()
	data.Ready(cross(cur))
}

// OfferAdmin offers the admin role to an address (offering it to the admin
// cancels the offer); AcceptAdmin takes it. Each change is mirrored to the
// data realm, so the next release keeps the admin.
func OfferAdmin(cur realm, to address) {
	onlyAdmin(cur)
	admin.Offer(0, cur, to)
}

func AcceptAdmin(cur realm) {
	noPayment()
	syncAdmin()
	if admin == nil {
		panic("radio: nothing offered to you")
	}
	admin.Accept(0, cur)
	data.Set(cross(cur), cConfig, "admin", admin.Holder().String())
}

// RenounceAdmin gives the admin role up for good, for this release and the
// next ones.
func RenounceAdmin(cur realm) {
	onlyAdmin(cur)
	admin.Renounce(0, cur)
	data.Set(cross(cur), cConfig, "admin", "")
}

// DropSlot silences a track in one station's rotation (moderation of last
// resort). It stays silent through Refresh until RestoreSlot. Radio admin only.
func DropSlot(cur realm, stationID, trackID int) {
	onlyAdmin(cur)
	t := rd()
	st := t.station(stationID)
	i, ok := st.slot(trackID)
	if st.id == MainStation {
		ok = trackID >= 1 && trackID <= t.synced() // Main simulcasts: the drop flag alone silences it there
	}
	if !ok {
		panic("radio: track not in this station's rotation")
	}
	ts := now()
	if !t.has(cDropped, dropKey(st.id, trackID)) {
		t.set(cDropped, dropKey(st.id, trackID), "1")
		t.setFlowAt(fDrops, 4, t.flowAt(fDrops, 4)+1)
	}
	if st.id != MainStation {
		st.setDuration(i, 0, ts)
	}
	release(cur, st.dropSlots(trackID, ts))
	save(cur, t)
	chain.Emit("SlotDropped", "station", text.Itoa(st.id), "track", text.Itoa(trackID))
}

// RestoreSlot undoes DropSlot: the track plays again on that station if the
// catalog still allows it. Radio admin only.
func RestoreSlot(cur realm, stationID, trackID int) {
	onlyAdmin(cur)
	mustStation(stationID)
	t := rd()
	if !t.del(cDropped, dropKey(stationID, trackID)) {
		panic("radio: this slot was not dropped")
	}
	t.setFlowAt(fDrops, 4, t.flowAt(fDrops, 4)-1)
	refresh(cur, t, trackID)
	save(cur, t)
	chain.Emit("SlotRestored", "station", text.Itoa(stationID), "track", text.Itoa(trackID))
}

// Unqueue removes a track's programmed slots from a station; one on air ends
// now. Radio admin (curator) only.
func Unqueue(cur realm, stationID, trackID int) {
	onlyAdmin(cur)
	t := rd()
	st := t.station(stationID)
	release(cur, st.dropSlots(trackID, now()))
	save(cur, t)
	chain.Emit("Unqueued", "station", text.Itoa(st.id), "track", text.Itoa(trackID))
}

// Render points gnoweb visitors to the GnoRadio site; a retired release says
// which realm took over.
func Render(_ string) string {
	home := strings.TrimPrefix(strings.TrimSuffix(self, "radio/v1"), "gno.land") + "home/v1"
	d := strings.TrimPrefix(dataPath, "gno.land")
	out := "# GnoRadio · radio\n\nThis contract holds GnoRadio's radio rules; its data lives in [" + d + "](" + d +
		"). The site lives at [" + home + "](" + home + ").\n"
	if w := data.Writer("radio"); w != self {
		out += "\nThis release is retired: the radio is now `" + w + "`.\n"
	}
	return out
}
