package bolo

// init refuses to deploy the registry from its admin's own key (API §3.7, §3.6, ADR
// D11): the key that deploys under the namespace must not also be the admin, or one
// stolen key could deploy a malicious version and point the registry at it.
func init(cur realm) {
	if cur.Previous().Address() == adminAddr {
		panic("bolo registry: the admin key may not deploy the registry; deploy from the namespace key, which must not be the admin")
	}
}
