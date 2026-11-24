// PKGPATH: gno.land/r/demo/lending
package lending

// Another realm integrates Bouncer: it gets policies from Bouncer's
// constructors (a bouncer.Policy{...} literal written here would panic:
// the VM refuses to allocate a Bouncer type in this realm) and calls the
// plain reads. An unattested package never passes, whatever the policy.

import bouncer "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v0"

func main(cur realm) {
	vault := "gno.land/r/demo/vault"
	println("strict:", bouncer.Check(vault, bouncer.Strict()))
	println("standard:", bouncer.Check(vault, bouncer.Standard()))
	println("custom:", bouncer.Check(vault, bouncer.Custom(0).WithProvenCritical().WithProvenOther().WithOpenDisputes()))
	s, ok := bouncer.Score(vault)
	println("score:", s, ok)
	a, ok := bouncer.Latest(vault)
	println("latest:", a.Score, ok, len(a.Findings))
}

// Output:
// strict: false
// standard: false
// custom: false
// score: 0 false
// latest: 0 false 0
