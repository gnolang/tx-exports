package kourtv3
func HandOver(cur realm, to address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if !to.IsValid() {
		panic("kourtv3: not a valid address")
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if who != d.admin {
		panic("kourtv3: only the global DAO admin hands over")
	}
	if to == who {
		panic("kourtv3: hand over to a different address")
	}
	seatGlobalMember(d, to)
	d.admin = to
	if d.members.Has(who.String()) {
		d.members.Remove(who.String())
		d.n--
		if d.purgeM > d.n {
			d.purgeM = d.n
		}
		clearPendingOnMembershipChange(&d.pending)
	}
	directoryAdmin = to
	courts.Iterate("", "", func(_ string, v any) bool {
		c := v.(*Court)
		if c.admin != who {
			return false
		}
		c.admin = to
		if cm := c.mod; cm != nil && !cm.creatorUnseated {
			if cm.members.Has(who.String()) {
				cm.members.Remove(who.String())
				cm.n--
			}
			if !cm.members.Has(to.String()) {
				cm.members.Set(to.String(), true)
				cm.n++
			}
			if cm.m > cm.n {
				cm.m = cm.n
			}
			clearPendingOnMembershipChange(&cm.pending)
		}
		return false
	})
}
