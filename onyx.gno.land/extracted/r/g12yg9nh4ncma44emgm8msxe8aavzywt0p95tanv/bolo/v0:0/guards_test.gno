package bolo

import (
	"math"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func TestCheckAddress(t *testing.T) {
	good := testutils.TestAddress("beneficiary")
	checkAddress(good, ErrBeneficiary)

	bad := string(good)
	last := "q"
	if bad[39] == 'q' {
		last = "p"
	}
	for name, a := range map[string]address{
		"empty":        "",
		"39 chars":     address(bad[:39]),
		"41 chars":     address(bad + "q"),
		"bad checksum": address(bad[:39] + last),
		"not bech32":   address("0x00000000000000000000000000000000000000"),
		// IsValid takes an address in capitals, as the same account; it must not
		// pass as a second address (API C12). Mixed case is refused by IsValid.
		"capitals":   address(strings.ToUpper(bad)),
		"mixed case": address(bad[:20] + strings.ToUpper(bad[20:])),
	} {
		if !panicsWith(func() { checkAddress(a, ErrBeneficiary) }, ErrBeneficiary) {
			t.Errorf("%s: not refused", name)
		}
	}
}

func TestDaysToSeconds(t *testing.T) {
	if got := daysToSeconds(0, ErrSetting); got != 0 {
		t.Errorf("0 days = %d", got)
	}
	if got := daysToSeconds(3650, ErrSetting); got != 315360000 {
		t.Errorf("3650 days = %d", got)
	}
	for _, days := range []int{-1, math.MaxInt64/secondsPerDay + 1, math.MaxInt64} {
		if !panicsWith(func() { daysToSeconds(days, ErrSetting) }, ErrSetting) {
			t.Errorf("%d days: not refused", days)
		}
	}
}

func TestNow(t *testing.T) {
	start := now()
	testing.SkipHeights(12)
	if got := now() - start; got != 60 {
		t.Errorf("12 heights moved now() by %d seconds, want 60", got)
	}
}
