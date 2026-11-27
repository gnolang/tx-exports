package slotswitch

type bookingRef struct {
	clinicID int
	slotID   int
	start    int64
}

type schedule map[address]map[int64]bookingRef

var holderSchedule = make(schedule)
var issuerSchedule = make(schedule)

// All appointments have equal duration. A non-overlapping calendar can
// contain at most one appointment beginning in each duration-sized bucket.
func scheduleConflict(index schedule, account address, start int64, released bookingRef) bool {
	calendar := index[account]
	bucket := start / appointmentSeconds
	for candidate := bucket - 1; candidate <= bucket+1; candidate++ {
		existing := calendar[candidate]
		if existing.slotID != 0 && existing != released &&
			start > existing.start-appointmentSeconds && existing.start > start-appointmentSeconds {
			return true
		}
	}
	return false
}

func addSchedule(index schedule, account address, ref bookingRef) {
	calendar := index[account]
	if calendar == nil {
		calendar = make(map[int64]bookingRef)
		index[account] = calendar
	}
	calendar[ref.start/appointmentSeconds] = ref
}

func removeSchedule(index schedule, account address, start int64) {
	calendar := index[account]
	delete(calendar, start/appointmentSeconds)
	if len(calendar) == 0 {
		delete(index, account)
	}
}

func addHolderBooking(c *clinic, slotID int, s slot) {
	if s.holder == "" {
		return
	}
	addSchedule(holderSchedule, s.holder, bookingRef{c.id, slotID, s.start})
	c.activeByHolder[s.holder] = slotID
	c.bookingGeneration[s.holder]++
}

func removeHolderBooking(c *clinic, s slot) {
	if s.holder == "" {
		return
	}
	removeSchedule(holderSchedule, s.holder, s.start)
	delete(c.activeByHolder, s.holder)
	c.bookingGeneration[s.holder]++
}

func planTimeConflict(c *clinic, p *plan) bool {
	for i := 0; i < p.size; i++ {
		destination := (i + 1) % p.size
		old := p.old[i]
		released := bookingRef{c.id, p.slots[i], old.start}
		if scheduleConflict(holderSchedule, old.holder, p.old[destination].start, released) {
			return true
		}
	}
	return false
}
