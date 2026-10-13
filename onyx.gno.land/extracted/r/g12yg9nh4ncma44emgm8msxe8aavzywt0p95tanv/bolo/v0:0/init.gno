package bolo

// init refuses to deploy Bolo from its admin's own key (API §3.6, ADR D11). The
// key that deploys under the namespace must not also be the admin: one stolen key
// could otherwise deploy a malicious version and point the registry at it. Then it
// lists the launch categories for lookups (API §2.1).
func init(cur realm) {
	if cur.Previous().Address() == adminAddr {
		panic("bolo: the admin key may not deploy Bolo; deploy from the namespace key, which must not be the admin")
	}
	for _, code := range categoryOrder {
		categories.Set(code, true)
	}
}
