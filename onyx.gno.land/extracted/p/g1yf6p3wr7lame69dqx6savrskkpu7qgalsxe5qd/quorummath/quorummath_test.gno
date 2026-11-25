package quorummath

import (
	"chain"
	"testing"
)

func TestValidateQuorum(t *testing.T) {
	if msg := ValidateQuorum(3, 2); msg != "" {
		t.Fatalf("expected valid quorum, got %s", msg)
	}
	if msg := ValidateQuorum(1, 1); msg != "" {
		t.Fatalf("expected valid 1-of-1 quorum, got %s", msg)
	}
	if ValidateQuorum(0, 1) == "" {
		t.Fatal("expected error for 0 reviewers")
	}
	if ValidateQuorum(3, 0) == "" {
		t.Fatal("expected error for 0 quorum")
	}
	if ValidateQuorum(2, 3) == "" {
		t.Fatal("expected error for quorum > reviewers")
	}
}

func TestParseCSVAddresses(t *testing.T) {
	a1 := chain.PackageAddress("gno.land/r/test/rev1")
	a2 := chain.PackageAddress("gno.land/r/test/rev2")

	addrs, errMsg := ParseCSVAddresses(a1.String() + ", " + a2.String())
	if errMsg != "" {
		t.Fatalf("unexpected error: %s", errMsg)
	}
	if len(addrs) != 2 || addrs[0] != a1 || addrs[1] != a2 {
		t.Fatalf("unexpected parsed addrs: %v", addrs)
	}

	if _, errMsg = ParseCSVAddresses(a1.String() + "," + a1.String()); errMsg == "" {
		t.Fatal("expected duplicate address error")
	}
	if _, errMsg = ParseCSVAddresses("not_a_valid_addr"); errMsg == "" {
		t.Fatal("expected invalid address error")
	}
	if _, errMsg = ParseCSVAddresses(" , "); errMsg == "" {
		t.Fatal("expected empty list error")
	}
}

func TestComputeMilestonePayout_ZeroDust(t *testing.T) {
	total := int64(1000)
	p1 := ComputeMilestonePayout(total, total, 3333, false)
	rem := total - p1
	p2 := ComputeMilestonePayout(total, rem, 3333, false)
	rem -= p2
	p3 := ComputeMilestonePayout(total, rem, 3334, true)

	if p1 != 333 || p2 != 333 || p3 != 334 || p1+p2+p3 != total {
		t.Fatalf("dust mismatch: p1=%d p2=%d p3=%d sum=%d", p1, p2, p3, p1+p2+p3)
	}
}

func TestQuorumOutcome(t *testing.T) {
	cases := []struct {
		n, q, a, r int
		want       string
	}{
		{3, 2, 1, 0, "pending"},
		{3, 2, 1, 1, "pending"},
		{3, 2, 2, 0, "approved"},
		{3, 2, 2, 1, "approved"},
		{3, 2, 0, 2, "rejected"},
		{3, 2, 1, 2, "rejected"},
	}
	for _, tc := range cases {
		if got := QuorumOutcome(tc.n, tc.q, tc.a, tc.r); got != tc.want {
			t.Fatalf("QuorumOutcome(%d,%d,%d,%d)=%s want %s", tc.n, tc.q, tc.a, tc.r, got, tc.want)
		}
	}
}

func TestFormatUGNOTAndProgressBar(t *testing.T) {
	if got := FormatUGNOT(1500000); got != "1.50 GNOT" {
		t.Fatalf("got %s", got)
	}
	if got := FormatUGNOT(1); got != "0.000001 GNOT" {
		t.Fatalf("got %s", got)
	}
	if got := FormatUGNOT(10000000); got != "10.00 GNOT" {
		t.Fatalf("got %s", got)
	}
	if got := ProgressBar(5000, 10); got != "[#####-----] 50%" {
		t.Fatalf("got %s", got)
	}
	if got := ProgressBar(10000, 10); got != "[##########] 100%" {
		t.Fatalf("got %s", got)
	}
}
