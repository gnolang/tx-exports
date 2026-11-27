// Package greedystore is a deliberately vulnerable demo registry realm for
// RealmCheck, the Gno.land audit demo entry for the Gnome Tavern Hackathon.
//
// It is a registry of entries that anyone can append to. It is intentionally
// insecure: there is no cap on the number of entries, no limit on the size of
// an entry, and no caller check at all, so storage (and the storage deposit
// that pays for it) grows without bound as long as anyone keeps calling
// Register.
//
// Demo only. Do not use this code for a real registry.
package greedystore

import "strconv"

// Entry is one stored registry record.
type Entry struct {
	ID     int64
	Author address
	Title  string
	Data   string
}

// entries holds every registered entry, in registration order. It is never
// pruned, capped, or paged.
var entries []Entry

// nextID is the ID assigned to the next entry.
var nextID int64

// Register appends a new entry to the registry and returns its ID.
//
// INTENTIONAL VULNERABILITY (demo): unbounded storage growth, and public
// state mutation with no guard. This function appends to a persistent slice
// on every call, with no maximum entry count, no maximum entry size, no
// per-user quota, no deduplication, and no caller check of any kind. Each
// call permanently grows on-chain state, so the storage deposit grows
// without bound and a single caller can bloat the realm forever at will.
// A safe version would cap the total count, cap the size of each entry,
// charge or rate limit callers, and restrict who may register.
func Register(cur realm, title string, data string) int64 {
	author := cur.Previous().Address()
	if title == "" {
		panic("title must not be empty")
	}
	id := nextID
	nextID++
	entries = append(entries, Entry{
		ID:     id,
		Author: author,
		Title:  title,
		Data:   data,
	})
	return id
}

// EntryCount returns the number of stored entries.
func EntryCount() int {
	return len(entries)
}

// GetEntry returns the entry with the given ID, and false if there is none.
func GetEntry(id int64) (Entry, bool) {
	for _, e := range entries {
		if e.ID == id {
			return e, true
		}
	}
	return Entry{}, false
}

// Render returns a short human readable summary of the registry.
func Render(path string) string {
	return "# Greedy Store\n\n" +
		"Demo registry for RealmCheck. Storage grows without bound.\n\n" +
		"Entries: " + strconv.Itoa(len(entries)) + "\n"
}
