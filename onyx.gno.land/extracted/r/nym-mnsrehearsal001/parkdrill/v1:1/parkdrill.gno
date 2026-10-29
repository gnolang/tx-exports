// Package parkdrill is a throwaway for the onyx-1 rehearsal (2026-10-16):
// it is submitted once with a storage ceiling too low to be charged, to see
// it park (inert), and then re-submitted at the same path by the same key,
// which is the retry deploy-gen.sh's RESUBMIT=1 relies on (re-audit M-6).
package parkdrill

var notes = []string{
	"a parked package is re-submitted by its creator at the same path",
	"the approver charges the storage deposit when it enables the package",
}

func Render(path string) string {
	out := "# park drill\n\n"
	for _, n := range notes {
		out += "- " + n + "\n"
	}
	return out
}
