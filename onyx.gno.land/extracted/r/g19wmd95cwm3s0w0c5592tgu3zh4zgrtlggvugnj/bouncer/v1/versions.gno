package bouncer

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Versions group the attested paths of one package: gno.land/r/x/vault/v1,
// .../v2 and so on. Packages on Gno cannot be overwritten, so a fix ships
// at a new /vN path, and the Passport shows every version side by side.

var families = avl.NewTree() // base path -> *avl.Tree (zero-padded N -> pkgpath)

// familyOf splits ".../name/vN" into its base and N.
func familyOf(pkgpath string) (base string, n int, ok bool) {
	i := strings.LastIndex(pkgpath, "/")
	if i < 0 {
		return "", 0, false
	}
	last := pkgpath[i+1:]
	if len(last) < 2 || len(last) > 7 || last[0] != 'v' {
		return "", 0, false
	}
	n, err := strconv.Atoi(last[1:])
	if err != nil || n < 0 || last[1:] != strconv.Itoa(n) {
		return "", 0, false
	}
	base = pkgpath[:i]
	if strings.Count(base, "/") < 2 { // need gno.land/r/<ns>/...
		return "", 0, false
	}
	return base, n, true
}

func versionKey(n int) string {
	s := strconv.Itoa(n)
	return strings.Repeat("0", 6-len(s)) + s
}

func addToFamily(pkgpath string) {
	base, n, ok := familyOf(pkgpath)
	if !ok {
		return
	}
	var t *avl.Tree
	if v := families.Get(base); v != nil {
		t = v.(*avl.Tree)
	} else {
		t = avl.NewTree()
		families.Set(base, t)
	}
	t.Set(versionKey(n), pkgpath)
}

// Versions returns every attested version of pkgpath's package, oldest
// first. A path without a /vN suffix is its own only version.
func Versions(pkgpath string) []string {
	out := []string{}
	base, _, ok := familyOf(pkgpath)
	if !ok {
		if getRecord(pkgpath) != nil {
			out = append(out, pkgpath)
		}
		return out
	}
	v := families.Get(base)
	if v == nil {
		return out
	}
	v.(*avl.Tree).Iterate("", "", func(_ string, p any) bool {
		out = append(out, p.(string))
		return false
	})
	return out
}
