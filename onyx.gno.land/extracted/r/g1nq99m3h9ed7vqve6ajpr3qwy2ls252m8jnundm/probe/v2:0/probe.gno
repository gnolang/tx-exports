// Package probe is a deliberately trivial realm whose only purpose is to answer one question:
// does a NEW package submitted to onyx today get enabled by the package approver, or does it park?
//
// Submitted 2026-10-19 after gno.land said the Friday chain upgrade probably had the approver off
// at the moment garden/v6 was submitted (2026-10-16 16:15 UTC, the same day). probe/v1 was
// submitted on 2026-10-16 and parked, so this is the same experiment on a day the approver may be
// back. Nothing in the project depends on this realm.
package probe

func Render(path string) string {
	return "probe v2, 2026-10-19: submitted to find out whether the package approver is running."
}
