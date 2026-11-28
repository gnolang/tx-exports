// Smoke-test realm for the Gnome Tavern hackathon.
// A minimal persistent counter, written from scratch.
// Deployed to the Onyx testnet as
// gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/counter.
package counter

import "strconv"

// count is the persistent counter value, stored on-chain in realm state.
var count int

// Increment raises the counter by one and returns the new value.
// The `_ realm` parameter makes this a crossing function: called from
// another realm (or a transaction via gnokey) it switches scope into
// this realm, which is what allows it to update the realm's state.
func Increment(_ realm) int {
	count++
	return count
}

// GetCount returns the current counter value.
func GetCount() int {
	return count
}

// Render renders the realm as a web page.
func Render(path string) string {
	return "# Smoke Test Counter\n\n" +
		"Current count: " + strconv.Itoa(count) + "\n\n" +
		"Call `Increment()` to raise the count by one.\n"
}
