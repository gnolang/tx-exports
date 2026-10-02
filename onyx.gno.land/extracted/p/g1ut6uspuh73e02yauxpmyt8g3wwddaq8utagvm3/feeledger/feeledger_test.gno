package feeledger

import "testing"

const (
	maxInt64 = int64(1<<63 - 1)
	minInt64 = int64(-1 << 63)
)

// mustPanicWith asserts fn panics with an error whose message is want.
// Non-crossing panics in the same package are recoverable.
func mustPanicWith(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatalf("expected panic %q, got none", want)
		}
		err, ok := r.(error)
		if !ok || err.Error() != want {
			t.Fatalf("panic = %v, want %q", r, want)
		}
	}()
	fn()
}

func TestNewBounds(t *testing.T) {
	for _, bad := range []int64{-1, BpsDenominator + 1, minInt64, maxInt64} {
		if _, err := New(bad); err != ErrInvalidBps {
			t.Fatalf("New(%d) err = %v, want ErrInvalidBps", bad, err)
		}
	}
	for _, ok := range []int64{0, 1, BpsDenominator} {
		if _, err := New(ok); err != nil {
			t.Fatalf("New(%d) err = %v", ok, err)
		}
	}
	mustPanicWith(t, ErrInvalidBps.Error(), func() { MustNew(-1) })
}

func TestFeeForRounding(t *testing.T) {
	// floor(max * 0.9999) computed the same overflow-free way feeFor does.
	wantMaxAt9999 := maxInt64/10000*9999 + maxInt64%10000*9999/10000
	cases := []struct {
		amount, bps, want int64
	}{
		{999, 100, 9},      // 9.99 floors to 9
		{10000, 1, 1},      // exact
		{9999, 1, 0},       // 0.9999 floors to 0 — no minimum fee
		{1, 9999, 0},       // 0.9999 floors to 0
		{10, 9999, 9},      // 9.999 floors to 9
		{100, 10000, 100},  // full-fee bps: fee == amount
		{0, 500, 0},        // zero amount previews zero fee
		{1000, 0, 0},       // zero-fee config
		{1000, 250, 25},    // exact 2.5%
		{999, 250, 24},     // 24.975 floors to 24
		{maxInt64, 10000, maxInt64}, // no intermediate overflow
		{maxInt64, 9999, wantMaxAt9999},
	}
	for _, c := range cases {
		got, err := FeeFor(c.amount, c.bps)
		if err != nil {
			t.Fatalf("FeeFor(%d,%d) err = %v", c.amount, c.bps, err)
		}
		if got != c.want {
			t.Fatalf("FeeFor(%d,%d) = %d, want %d", c.amount, c.bps, got, c.want)
		}
		if got < 0 || got > c.amount {
			t.Fatalf("FeeFor(%d,%d) = %d out of [0,amount]", c.amount, c.bps, got)
		}
	}
	if _, err := FeeFor(-1, 100); err != ErrInvalidAmount {
		t.Fatalf("FeeFor(-1,100) err = %v, want ErrInvalidAmount", err)
	}
	if _, err := FeeFor(100, -1); err != ErrInvalidBps {
		t.Fatalf("FeeFor(100,-1) err = %v, want ErrInvalidBps", err)
	}
	if _, err := FeeFor(100, BpsDenominator+1); err != ErrInvalidBps {
		t.Fatalf("FeeFor over-bps err = %v, want ErrInvalidBps", err)
	}
}

func TestDepositValidation(t *testing.T) {
	l := MustNew(500)
	type bad struct {
		account     string
		amount, bps int64
		want        error
	}
	for _, c := range []bad{
		{"", 100, 0, ErrEmptyAccount},
		{"alice", 0, 0, ErrInvalidAmount},
		{"alice", -7, 0, ErrInvalidAmount},
		{"alice", minInt64, 0, ErrInvalidAmount},
		{"alice", 100, -1, ErrInvalidBps},
		{"alice", 100, 501, ErrInvalidBps}, // above the ledger cap
	} {
		if _, _, err := l.Deposit(c.account, c.amount, c.bps); err != c.want {
			t.Fatalf("Deposit(%q,%d,%d) err = %v, want %v", c.account, c.amount, c.bps, err, c.want)
		}
	}
	if l.UsersTotal() != 0 || l.FeesAccrued() != 0 || l.Accounts() != 0 {
		t.Fatal("failed deposits mutated state")
	}
}

func TestDepositAndAccumulate(t *testing.T) {
	l := MustNew(1000)
	credited, fee, err := l.Deposit("alice", 1000, 250)
	if err != nil || credited != 975 || fee != 25 {
		t.Fatalf("Deposit = (%d,%d,%v), want (975,25,nil)", credited, fee, err)
	}
	credited, fee, err = l.Deposit("alice", 999, 250)
	if err != nil || credited != 975 || fee != 24 { // fee floors, credit rounds up
		t.Fatalf("Deposit#2 = (%d,%d,%v), want (975,24,nil)", credited, fee, err)
	}
	if got := l.BalanceOf("alice"); got != 1950 {
		t.Fatalf("BalanceOf = %d, want 1950", got)
	}
	if l.UsersTotal() != 1950 || l.FeesAccrued() != 49 || l.Liabilities() != 1999 {
		t.Fatalf("totals = %d/%d/%d", l.UsersTotal(), l.FeesAccrued(), l.Liabilities())
	}
	// credited + fee always reassembles both deposits exactly.
	if l.Liabilities() != 1000+999 {
		t.Fatal("conservation broken: credited+fee != deposited")
	}
}

func TestFullFeeBpsCreditsZero(t *testing.T) {
	l := MustNew(BpsDenominator)
	credited, fee, err := l.Deposit("alice", 777, BpsDenominator)
	if err != nil || credited != 0 || fee != 777 {
		t.Fatalf("Deposit = (%d,%d,%v), want (0,777,nil)", credited, fee, err)
	}
	if l.Accounts() != 0 || l.BalanceOf("alice") != 0 {
		t.Fatal("zero-credit deposit must not create an account entry")
	}
	if l.FeesAccrued() != 777 || l.UsersTotal() != 0 {
		t.Fatal("fee pot mismatch on full-fee deposit")
	}
}

func TestDepositOverflow(t *testing.T) {
	l := MustNew(BpsDenominator)
	if _, _, err := l.Deposit("alice", maxInt64, 0); err != nil {
		t.Fatalf("seed deposit err = %v", err)
	}
	// Account balance would overflow.
	if _, _, err := l.Deposit("alice", 1, 0); err != ErrOverflow {
		t.Fatalf("balance-overflow err = %v, want ErrOverflow", err)
	}
	// Joint liabilities (users + fees) would overflow even though the
	// fee pot alone would not.
	if _, _, err := l.Deposit("bob", 100, BpsDenominator); err != ErrOverflow {
		t.Fatalf("liabilities-overflow err = %v, want ErrOverflow", err)
	}
	if l.BalanceOf("bob") != 0 || l.FeesAccrued() != 0 || l.UsersTotal() != maxInt64 {
		t.Fatal("failed overflow deposits mutated state")
	}
}

func TestWithdraw(t *testing.T) {
	l := MustNew(0)
	l.MustDeposit("alice", 1000, 0)

	if err := l.Withdraw("", 10); err != ErrEmptyAccount {
		t.Fatalf("empty account err = %v", err)
	}
	if err := l.Withdraw("alice", 0); err != ErrInvalidAmount {
		t.Fatalf("zero amount err = %v", err)
	}
	if err := l.Withdraw("alice", -3); err != ErrInvalidAmount {
		t.Fatalf("negative amount err = %v", err)
	}
	if err := l.Withdraw("alice", 1001); err != ErrInsufficient {
		t.Fatalf("over-balance err = %v", err)
	}
	if err := l.Withdraw("ghost", 1); err != ErrInsufficient {
		t.Fatalf("absent account err = %v", err)
	}
	if l.BalanceOf("alice") != 1000 || l.UsersTotal() != 1000 {
		t.Fatal("failed withdrawals mutated state")
	}

	if err := l.Withdraw("alice", 400); err != nil {
		t.Fatalf("partial withdraw err = %v", err)
	}
	if l.BalanceOf("alice") != 600 || l.UsersTotal() != 600 || l.Accounts() != 1 {
		t.Fatal("partial withdraw wrong state")
	}
	if err := l.Withdraw("alice", 600); err != nil {
		t.Fatalf("exact withdraw err = %v", err)
	}
	if l.BalanceOf("alice") != 0 || l.UsersTotal() != 0 || l.Accounts() != 0 {
		t.Fatal("exact withdraw must remove the account entry")
	}
	if err := l.Withdraw("alice", 1); err != ErrInsufficient {
		t.Fatalf("repeat withdraw err = %v, want ErrInsufficient", err)
	}
	mustPanicWith(t, ErrInsufficient.Error(), func() { l.MustWithdraw("alice", 1) })
}

func TestWithdrawAll(t *testing.T) {
	l := MustNew(0)
	if got, err := l.WithdrawAll("nobody"); err != nil || got != 0 {
		t.Fatalf("WithdrawAll(nobody) = (%d,%v), want (0,nil)", got, err)
	}
	if _, err := l.WithdrawAll(""); err != ErrEmptyAccount {
		t.Fatalf("WithdrawAll(\"\") err = %v", err)
	}
	l.MustDeposit("alice", 555, 0)
	if got, err := l.WithdrawAll("alice"); err != nil || got != 555 {
		t.Fatalf("WithdrawAll = (%d,%v), want (555,nil)", got, err)
	}
	if got, err := l.WithdrawAll("alice"); err != nil || got != 0 {
		t.Fatalf("repeat WithdrawAll = (%d,%v), want (0,nil)", got, err)
	}
	if l.UsersTotal() != 0 || l.Accounts() != 0 {
		t.Fatal("WithdrawAll left state behind")
	}
}

func TestWithdrawFees(t *testing.T) {
	l := MustNew(1000)
	l.MustDeposit("alice", 10000, 1000) // fee 1000
	l.MustDeposit("bob", 10000, 1000)   // fee 1000
	if got := l.WithdrawFees(); got != 2000 {
		t.Fatalf("WithdrawFees = %d, want 2000", got)
	}
	if got := l.WithdrawFees(); got != 0 {
		t.Fatalf("repeat WithdrawFees = %d, want 0", got)
	}
	if l.FeesAccrued() != 0 || l.UsersTotal() != 18000 {
		t.Fatal("WithdrawFees corrupted totals")
	}
}

func TestConservationAcrossSequence(t *testing.T) {
	l := MustNew(1000)
	deposited := int64(0)
	withdrawn := int64(0)
	feesOut := int64(0)

	step := func() {
		t.Helper()
		// Internal consistency: usersTotal == sum of balances.
		sum := int64(0)
		l.Iterate(func(_ string, b int64) bool {
			if b <= 0 {
				t.Fatal("zero/negative balance stored")
			}
			sum += b
			return false
		})
		if sum != l.UsersTotal() {
			t.Fatalf("usersTotal %d != Σ balances %d", l.UsersTotal(), sum)
		}
		// Conservation: everything in == everything owed + everything out.
		if deposited != l.Liabilities()+withdrawn+feesOut {
			t.Fatalf("conservation: in=%d owed=%d out=%d+%d",
				deposited, l.Liabilities(), withdrawn, feesOut)
		}
	}

	deposit := func(who string, amt, bps int64) {
		l.MustDeposit(who, amt, bps)
		deposited += amt
		step()
	}
	claim := func(who string, amt int64) {
		l.MustWithdraw(who, amt)
		withdrawn += amt
		step()
	}

	deposit("alice", 1000, 0)
	deposit("bob", 999, 250)
	deposit("alice", 12345, 1000)
	claim("alice", 1000)
	deposit("carol", 1, 1000) // fee floors to 0
	feesOut += l.WithdrawFees()
	step()
	claim("bob", 974)
	all, _ := l.WithdrawAll("alice")
	withdrawn += all
	step()
	deposit("dave", 7, 999)
	feesOut += l.WithdrawFees()
	step()
}

func TestCheckedAddBranches(t *testing.T) {
	cases := []struct {
		a, b, want int64
		ok         bool
	}{
		{5, 3, 8, true},
		{5, -3, 2, true},   // negative-b branch, no overflow
		{-4, -6, -10, true},
		{maxInt64, 1, 0, false},  // positive overflow
		{minInt64, -1, 0, false}, // negative overflow
		{maxInt64, -maxInt64, 0, true},
	}
	for _, c := range cases {
		got, ok := checkedAdd(c.a, c.b)
		if ok != c.ok || (ok && got != c.want) {
			t.Fatalf("checkedAdd(%d,%d) = (%d,%v), want (%d,%v)", c.a, c.b, got, ok, c.want, c.ok)
		}
	}
}

func TestIterateSortedAndEarlyStop(t *testing.T) {
	l := MustNew(0)
	l.MustDeposit("carol", 3, 0)
	l.MustDeposit("alice", 1, 0)
	l.MustDeposit("bob", 2, 0)
	got := ""
	l.Iterate(func(a string, _ int64) bool {
		got += a + ","
		return false
	})
	if got != "alice,bob,carol," {
		t.Fatalf("Iterate order = %q", got)
	}
	n := 0
	l.Iterate(func(string, int64) bool { n++; return n == 2 })
	if n != 2 {
		t.Fatalf("early stop visited %d", n)
	}
}
