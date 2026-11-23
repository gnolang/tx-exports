package escrow

import (
	"strings"
	"testing"
)

const (
	posterAddr   = address("g1wdjkuer9wgc47h6lta047h6lta047h6l56jtjc")
	claimerAddr  = address("g1wfjkx6tsd9jkuap3ta047h6lta047h6lkk20gv")
	strangerAddr = address("g1wfjkx6tsd9jkuapjta047h6lta047h6lducc3v")
)

func newQuest() *Quest {
	return &Quest{
		ID:          1,
		Poster:      posterAddr,
		Title:       "Write the tavern chronicle",
		Description: "A short history of the tavern, in markdown.",
		Reward:      1000,
		Status:      Open,
	}
}

func mustOK(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func mustErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error containing %q, got nil", want)
	}
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("expected error containing %q, got %q", want, err.Error())
	}
}

func TestValidateNew(t *testing.T) {
	mustOK(t, ValidateNew("A quest", "details", 1))
	mustErr(t, ValidateNew("", "details", 1), "title must not be empty")
	mustErr(t, ValidateNew("   ", "details", 1), "title must not be empty")
	mustErr(t, ValidateNew("A quest", "details", 0), "reward must be a positive")
	mustErr(t, ValidateNew("A quest", "details", -5), "reward must be a positive")
}

func TestHappyPath(t *testing.T) {
	q := newQuest()

	mustOK(t, Claim(q, claimerAddr))
	if q.Status != Claimed || q.Claimant != claimerAddr {
		t.Fatalf("after claim: status=%v claimant=%v", q.Status, q.Claimant)
	}

	mustOK(t, Submit(q, claimerAddr, "delivered: ipfs://chronicle-v1"))
	if q.Status != Submitted || q.Submission == "" {
		t.Fatalf("after submit: status=%v submission=%q", q.Status, q.Submission)
	}

	mustOK(t, Approve(q, posterAddr))
	if q.Status != Completed {
		t.Fatalf("after approve: status=%v", q.Status)
	}
}

func TestRejectReopensForResubmit(t *testing.T) {
	q := newQuest()
	mustOK(t, Claim(q, claimerAddr))
	mustOK(t, Submit(q, claimerAddr, "first draft"))

	mustOK(t, Reject(q, posterAddr))
	if q.Status != Claimed {
		t.Fatalf("after reject: status=%v, want claimed", q.Status)
	}
	if q.Submission != "" {
		t.Fatalf("after reject: submission not cleared: %q", q.Submission)
	}

	mustOK(t, Submit(q, claimerAddr, "second draft"))
	mustOK(t, Approve(q, posterAddr))
	if q.Status != Completed {
		t.Fatalf("final status=%v, want completed", q.Status)
	}
}

func TestCancelOpen(t *testing.T) {
	q := newQuest()
	mustOK(t, Cancel(q, posterAddr))
	if q.Status != Cancelled {
		t.Fatalf("after cancel: status=%v", q.Status)
	}
}

func TestDoubleClaimRejected(t *testing.T) {
	q := newQuest()
	mustOK(t, Claim(q, claimerAddr))
	mustErr(t, Claim(q, strangerAddr), "quest is not open")
	if q.Claimant != claimerAddr {
		t.Fatalf("claimant changed after double claim: %v", q.Claimant)
	}
}

func TestPosterCannotClaimOwn(t *testing.T) {
	q := newQuest()
	mustErr(t, Claim(q, posterAddr), "poster cannot claim their own quest")
	if q.Status != Open {
		t.Fatalf("status changed after self-claim attempt: %v", q.Status)
	}
}

func TestWrongApproverRejected(t *testing.T) {
	q := newQuest()
	mustOK(t, Claim(q, claimerAddr))
	mustOK(t, Submit(q, claimerAddr, "done"))
	mustErr(t, Approve(q, claimerAddr), "only the poster can approve")
	mustErr(t, Approve(q, strangerAddr), "only the poster can approve")
	mustErr(t, Reject(q, claimerAddr), "only the poster can reject")
	if q.Status != Submitted {
		t.Fatalf("status changed after wrong-approver attempts: %v", q.Status)
	}
}

func TestCancelAfterClaimRejected(t *testing.T) {
	q := newQuest()
	mustOK(t, Claim(q, claimerAddr))
	mustErr(t, Cancel(q, posterAddr), "only an open quest can be cancelled")
	if q.Status != Claimed {
		t.Fatalf("status changed after cancel-after-claim: %v", q.Status)
	}
}

func TestSubmitRules(t *testing.T) {
	q := newQuest()
	mustErr(t, Submit(q, claimerAddr, "too early"), "quest is not in claimed state")
	mustOK(t, Claim(q, claimerAddr))
	mustErr(t, Submit(q, strangerAddr, "not mine"), "only the claimant can submit work")
	mustErr(t, Submit(q, claimerAddr, "  "), "submission note must not be empty")
}

func TestTerminalStatesAreFinal(t *testing.T) {
	q := newQuest()
	mustOK(t, Cancel(q, posterAddr))
	mustErr(t, Claim(q, claimerAddr), "quest is not open")
	mustErr(t, Cancel(q, posterAddr), "only an open quest can be cancelled")

	q2 := newQuest()
	mustOK(t, Claim(q2, claimerAddr))
	mustOK(t, Submit(q2, claimerAddr, "done"))
	mustOK(t, Approve(q2, posterAddr))
	mustErr(t, Approve(q2, posterAddr), "quest is not in submitted state")
	mustErr(t, Cancel(q2, posterAddr), "only an open quest can be cancelled")
}
