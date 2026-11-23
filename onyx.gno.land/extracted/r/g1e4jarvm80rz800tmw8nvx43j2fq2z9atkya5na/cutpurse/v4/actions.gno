package cutpurse

import (
	"chain"
	"chain/banker"
)

// CreateJob opens a job and seats the creator (seat 0).
func CreateJob(cur realm, name string, fee int64) int64 {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	who := here(cur)
	if _, busy := active[who]; busy {
		panic(ErrSameJob)
	}
	if liveCount >= LiveJobsMax {
		panic(ErrTooManyLive)
	}
	if fee < 0 {
		panic(ErrBadFee)
	}

	f := clampFee(fee)
	nm := cleanName(name)
	height := mustHeight()

	payIn(cur, f)

	id := nextID
	nextID++

	j := &Job{
		ID:       id,
		Name:     nm,
		Creator:  who,
		Fee:      f,
		Pot:      f,
		Phase:    PhaseOpen,
		Deadline: height + JoinBlocks,
		Traitor:  -1,
		OpenedAt: height,
	}
	j.Seats[0] = Seat{Addr: who}
	j.NSeats = 1

	jobs[id] = j
	active[who] = id
	liveCount++

	return id
}

// JoinJob seats the caller in an open job.
func JoinJob(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	who := here(cur)
	j := mustJob(id)

	if j.Phase != PhaseOpen {
		panic(ErrBadPhase)
	}
	if mustHeight() > j.Deadline {
		panic(ErrDeadlinePassed)
	}
	if j.NSeats >= Seats {
		panic(ErrFull)
	}
	if seatOf(j, who) >= 0 {
		panic(ErrAlreadySeated)
	}
	if _, busy := active[who]; busy {
		panic(ErrSameJob)
	}
	if j.Pot+j.Fee > int64(MaxFee*Seats) {
		panic(ErrPotCap)
	}

	payIn(cur, j.Fee)

	j.Seats[j.NSeats] = Seat{Addr: who}
	j.NSeats++
	j.Pot += j.Fee
	active[who] = id
}

// Kick drops a seat during Open and refunds that seat's fee (creator only).
func Kick(cur realm, id int64, seat int8) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	who := here(cur)
	j := mustJob(id)

	if j.Creator != who {
		panic(ErrNotCreator)
	}
	if j.Phase != PhaseOpen {
		panic(ErrBadPhase)
	}
	if seat < 0 || int(seat) >= int(j.NSeats) {
		panic(ErrNotSeated)
	}

	idx := int(seat)
	kicked := j.Seats[idx]
	for i := idx; i < int(j.NSeats)-1; i++ {
		j.Seats[i] = j.Seats[i+1]
	}
	j.Seats[j.NSeats-1] = Seat{}
	j.NSeats--
	j.Pot -= j.Fee
	delete(active, kicked.Addr)

	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
		cur.Address(), kicked.Addr, chain.NewCoins(chain.NewCoin(Denom, j.Fee)))
}

// Start moves an open job into round 1 (creator only).
func Start(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	j := mustJob(id)

	if j.Creator != here(cur) {
		panic(ErrNotCreator)
	}
	if j.Phase != PhaseOpen {
		panic(ErrBadPhase)
	}
	if j.NSeats < 2 {
		panic(ErrNotReady)
	}

	j.Phase = PhaseCommit
	j.Round = 1
	j.Deadline = mustHeight() + CommitBlocks
}

// Commit stores the caller's sealed choice hash for the current round.
func Commit(cur realm, id int64, hash string) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	who := here(cur)
	j := mustJob(id)
	idx := seatOf(j, who)

	if idx < 0 {
		panic(ErrNotSeated)
	}
	if j.Phase != PhaseCommit {
		panic(ErrBadPhase)
	}
	if mustHeight() > j.Deadline {
		panic(ErrDeadlinePassed)
	}
	if j.Seats[idx].Committed {
		panic(ErrAlreadyComitted)
	}
	if !isHex64(hash) {
		panic(ErrBadHash)
	}

	j.Seats[idx].Committed = true
	j.Seats[idx].CommitHash = hash

	if countCommitted(j) == int(j.NSeats) {
		closeCommitRound(j)
	}
}

// Reveal opens the caller's sealed choice and applies nothing yet.
func Reveal(cur realm, id int64, action uint8, salt string) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	who := here(cur)
	j := mustJob(id)
	idx := seatOf(j, who)

	if idx < 0 {
		panic(ErrNotSeated)
	}
	if j.Phase != PhaseReveal {
		panic(ErrBadPhase)
	}
	if mustHeight() > j.Deadline {
		panic(ErrDeadlinePassed)
	}
	if j.Seats[idx].Action != ActNone {
		panic(ErrAlreadyComitted)
	}
	if !j.Seats[idx].Committed {
		// §8: an uncommitted reveal is a hash mismatch, not a readiness error
		panic(ErrHashMismatch)
	}
	if action < uint8(ActScout) || action > uint8(ActWatch) {
		panic(ErrBadAction)
	}
	if !validSalt(salt) {
		panic(ErrBadSalt)
	}
	if commitHash(j.ID, action, salt, who.String(), j.Round) != j.Seats[idx].CommitHash {
		panic(ErrHashMismatch)
	}

	j.Seats[idx].Action = Action(action)
	j.Seats[idx].Auto = false

	if countRevealed(j) == int(j.NSeats) {
		closeRevealRound(j, false)
	}
}
