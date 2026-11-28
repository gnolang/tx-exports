package budget

import "testing"

func TestLedgerConservesFunds(t *testing.T) {
	ledger := Ledger{}.Fund(1000000).Reserve(600000).Reserve(300000)
	checkLedger(t, ledger, Ledger{Funded: 1000000, Available: 100000, Reserved: 900000})
	ledger = ledger.Approve(300000).Pay(300000).Approve(600000).Reserve(100000)
	checkLedger(t, ledger, Ledger{Funded: 1000000, Reserved: 100000, Claimable: 600000, Paid: 300000})
	ledger = ledger.Release(100000).RefundAvailable()
	checkLedger(t, ledger, Ledger{Funded: 1000000, Claimable: 700000, Paid: 300000})
	ledger = ledger.Pay(100000).Pay(600000)
	checkLedger(t, ledger, Ledger{Funded: 1000000, Paid: 1000000})
}

func TestPeriodAndDeadlineBoundaries(t *testing.T) {
	if PeriodAt(119, 100, 20) != 0 || PeriodAt(120, 100, 20) != 1 || PeriodAt(140, 100, 20) != 2 {
		t.Fatal("period must change at its first height")
	}
	CheckDeadline(100, 120, 20)
	expectPanic(t, func() { CheckDeadline(100, 100, 20) })
	expectPanic(t, func() { CheckDeadline(100, 121, 20) })
}

func TestInvalidLedgerTransitions(t *testing.T) {
	expectPanic(t, func() { Ledger{}.Fund(0) })
	expectPanic(t, func() { Ledger{}.Reserve(1) })
	expectPanic(t, func() { Ledger{}.Approve(1) })
	expectPanic(t, func() { Ledger{}.Release(1) })
	expectPanic(t, func() { Ledger{}.Pay(1) })
	expectPanic(t, func() { Add(maxInt64, 1) })
	expectPanic(t, func() { Subtract(1, 2) })
}

func TestAddressAndEvidenceValidation(t *testing.T) {
	RequireAddress(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"))
	RequireDigest("29b3d9914b5af7272b4a89af0a9427ff6dc8ee75cf28739414fc2a46372fd38f")
	expectPanic(t, func() { RequireAddress(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf6")) })
	expectPanic(t, func() { RequireDigest("invalid") })
}

func TestEvidenceCommitmentBindsContext(t *testing.T) {
	proof := "29b3d9914b5af7272b4a89af0a9427ff6dc8ee75cf28739414fc2a46372fd38f"
	a := EvidenceCommitment(1, Maintenance, 1, proof)
	RequireDigest(a)
	if a == EvidenceCommitment(2, Maintenance, 1, proof) ||
		a == EvidenceCommitment(1, Reimbursements, 1, proof) ||
		a == EvidenceCommitment(1, Maintenance, 2, proof) {
		t.Fatal("evidence commitment did not bind the context")
	}
}

func checkLedger(t *testing.T, actual, expected Ledger) {
	if actual != expected {
		t.Fatalf("ledger got %+v, want %+v", actual, expected)
	}
	if actual.Funded != actual.Available+actual.Reserved+actual.Claimable+actual.Paid {
		t.Fatal("ledger does not conserve funds")
	}
}

func expectPanic(t *testing.T, run func()) {
	defer func() {
		if recover() == nil {
			t.Error("expected panic")
		}
	}()
	run()
}
