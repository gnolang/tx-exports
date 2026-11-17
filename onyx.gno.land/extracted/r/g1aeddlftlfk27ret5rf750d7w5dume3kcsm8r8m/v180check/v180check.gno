// Package v180check is deployed on onyx after the v1.8.0-rc.1 halt: its
// addpkg checks that a canonical transaction is included, and its enable that
// GPASO's transactions are.
package v180check

func Render(_ string) string {
	return "# v1.8.0-rc.1 check\n\nDeployed and enabled after onyx's halt at 1203400.\n"
}
