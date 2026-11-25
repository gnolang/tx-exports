// Package taletree is a realm for collaborative branching stories,
// read and written straight from gnoweb.
//
// Anyone can start a tale. Anyone can add the next passage under any
// passage, as a new choice, or close a path with an ending. Readers
// cheer the passages they like, once per address; the most-cheered
// choice at each step forms the tale's canon, a single read-through
// picked by readers. Tips sent to a passage go straight to its author.
//
// Every passage is a page (":p/<id>") and every choice is a link, so the
// whole library is browsable without any front-end:
//
//	""                home: totals and the list of tales
//	"tale/<id>"       a tale's opening and an outline of its branches
//	"tale/<id>/canon" the canon as one continuous read
//	"p/<id>"          one passage with its choices and actions
//	"bard/<address>"  a writer's profile
//	"bards"           the hall of fame, by cheers received
//
// Writing functions (StartTale, Branch, WriteEnding, Cheer, Tip) take
// the caller from cur.Previous(). Tip forwards the ugnot sent with the
// transaction to the passage author in the same call, so the realm never
// holds funds. Tale narrators and the realm keeper can hide passages
// and lock tales.
package taletree
