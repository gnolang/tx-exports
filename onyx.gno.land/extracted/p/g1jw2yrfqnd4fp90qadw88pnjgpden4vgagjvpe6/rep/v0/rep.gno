// Package rep keeps a public work record for each address: how many tasks
// it completed and was paid for, and how many tasks it posted and paid out.
//
// A Book holds no coins and makes no calls. A realm owns a Book and writes
// one Record each time it pays for finished work. Any realm can import this
// package to keep its own records, or read another realm's records through
// that realm's public functions.
package rep

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

// DefaultRecent is the number of recent records kept per address when
// NewBook is given a value below 1.
const DefaultRecent = 20

// Record is one paid piece of work.
type Record struct {
	TaskID string
	Title  string
	Poster address
	Doer   address
	Amount int64
	Denom  string
	At     time.Time
}

// Profile is the record of one address. It is returned by value, so callers
// cannot change the Book through it.
type Profile struct {
	Completed int   // tasks this address finished and was paid for
	Earned    int64 // total paid to this address
	Posted    int   // tasks this address paid out to someone else
	Spent     int64 // total this address paid out
	recent    []Record
}

// Recent returns the newest records first. The slice is a copy.
func (p Profile) Recent() []Record {
	out := make([]Record, len(p.recent))
	copy(out, p.recent)
	return out
}

// Book is a set of profiles, keyed by address.
type Book struct {
	profiles  avl.Tree // address string -> *Profile
	total     int
	volume    int64
	maxRecent int
}

// NewBook returns an empty Book that keeps up to maxRecent records per
// address.
func NewBook(maxRecent int) *Book {
	if maxRecent < 1 {
		maxRecent = DefaultRecent
	}
	return &Book{maxRecent: maxRecent}
}

// Add stores a paid record for both the doer and the poster.
// It panics if the record is not valid, so a realm cannot store a bad record
// by mistake.
func (b *Book) Add(r Record) {
	if !r.Doer.IsValid() {
		panic("rep: invalid doer address")
	}
	if !r.Poster.IsValid() {
		panic("rep: invalid poster address")
	}
	if r.Doer == r.Poster {
		panic("rep: doer and poster must differ")
	}
	if r.Amount <= 0 {
		panic("rep: amount must be positive")
	}
	if r.TaskID == "" {
		panic("rep: task id is required")
	}

	doer := b.mustProfile(r.Doer)
	if doer.Earned > maxInt64-r.Amount {
		panic("rep: earned overflow")
	}
	doer.Completed++
	doer.Earned += r.Amount
	doer.recent = b.prepend(doer.recent, r)

	poster := b.mustProfile(r.Poster)
	if poster.Spent > maxInt64-r.Amount {
		panic("rep: spent overflow")
	}
	poster.Posted++
	poster.Spent += r.Amount
	poster.recent = b.prepend(poster.recent, r)

	b.total++
	if b.volume <= maxInt64-r.Amount {
		b.volume += r.Amount
	}
}

// Profile returns a copy of the profile for addr. Unknown addresses return
// an empty profile.
func (b *Book) Profile(addr address) Profile {
	v := b.profiles.Get(addr.String())
	if v == nil {
		return Profile{}
	}
	p := v.(*Profile)
	return Profile{
		Completed: p.Completed,
		Earned:    p.Earned,
		Posted:    p.Posted,
		Spent:     p.Spent,
		recent:    p.recent,
	}
}

// Completed returns how many tasks addr finished and was paid for.
func (b *Book) Completed(addr address) int { return b.Profile(addr).Completed }

// Earned returns the total paid to addr.
func (b *Book) Earned(addr address) int64 { return b.Profile(addr).Earned }

// HasCompleted reports whether addr finished at least n tasks. Realms can use
// it to gate features by proven work.
func (b *Book) HasCompleted(addr address, n int) bool {
	return b.Completed(addr) >= n
}

// Total returns the number of paid records in the Book.
func (b *Book) Total() int { return b.total }

// Volume returns the total amount recorded, capped at the int64 maximum.
func (b *Book) Volume() int64 { return b.volume }

// Size returns the number of addresses with a profile.
func (b *Book) Size() int { return b.profiles.Size() }

const maxInt64 = int64(^uint64(0) >> 1)

func (b *Book) mustProfile(addr address) *Profile {
	key := addr.String()
	if v := b.profiles.Get(key); v != nil {
		return v.(*Profile)
	}
	p := &Profile{}
	b.profiles.Set(key, p)
	return p
}

func (b *Book) prepend(list []Record, r Record) []Record {
	n := len(list) + 1
	if n > b.maxRecent {
		n = b.maxRecent
	}
	out := make([]Record, n)
	out[0] = r
	copy(out[1:], list)
	return out
}
