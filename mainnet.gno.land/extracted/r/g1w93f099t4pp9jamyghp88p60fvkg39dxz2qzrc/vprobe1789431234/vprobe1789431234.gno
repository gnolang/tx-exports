// Package vprobe1789431234 is a throwaway realm deployed ONLY to confirm
// that gas fees and storage deposits can be paid from a vesting
// account's LOCKED balance, not just its free balance -- deployed
// deliberately while this account's free balance sits near zero, so
// success here can only mean the locked portion covered the cost.
package vprobe1789431234

func Render(path string) string {
	return "# vesting-payment probe\n\nConfirms gas/storage can be paid from a vesting account's locked balance."
}
