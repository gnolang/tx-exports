// Storage probe C: the regexp is compiled LAZILY, inside a call, and
// cached in a package-level var -- exactly what nslogic's currentLabelRe
// does. The question is who pays for it: the deployer, or whoever
// happens to make the first call.
package storeprobec

import "regexp"

var re *regexp.Regexp

func Warm(cur realm) bool {
	if re == nil {
		re = regexp.MustCompile(`^g1[a-z0-9]{20,38}$`)
	}
	return re.MatchString("g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku")
}

func Render(path string) string { return "probe c" }
