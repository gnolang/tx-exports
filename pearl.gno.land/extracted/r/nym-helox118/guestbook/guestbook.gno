package guestbook

type Entry struct {
	Author  address
	Message string
}

var entries = map[address]Entry{}

func Sign(cur realm, message string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if message == "" {
		panic("message cannot be empty")
	}

	if len(message) > 160 {
		panic("message is too long")
	}

	author := cur.Previous().Address()

	entries[author] = Entry{
		Author:  author,
		Message: message,
	}
}

func GetEntry(author address) Entry {
	return entries[author]
}

func HasEntry(author address) bool {
	entry := entries[author]
	return entry.Author.IsValid()
}

func Render(_ string) string {
	return "Pearl Guestbook aktif.\n" +
		"Gunakan fungsi Sign untuk menyimpan pesan."
}
