package poll

import (
	"strings"
	"testing"

	"chain"
)

// Deterministic test addresses, derived from fixed package paths.
func alice() address { return chain.PackageAddress("gno.land/r/test/alice") }
func bob() address   { return chain.PackageAddress("gno.land/r/test/bob") }
func carol() address { return chain.PackageAddress("gno.land/r/test/carol") }

// reset clears realm state. gno test runs all test functions in this file
// against the same store, so each test must start from a clean slate
// (same pattern as the counter example resetting its counter).
func reset() {
	polls = nil
}

// NOTE: testing.SetRealm is frame-scoped: it must be called in the same
// function frame that performs the cross(cur) call, otherwise the crossing
// function sees the test realm instead of the simulated user. That is why
// the helpers below each do SetRealm + the cross call in their own body
// instead of delegating SetRealm to a separate helper.

func createPollAs(cur realm, t *testing.T, creator address, question string, options string) int {
	testing.SetRealm(testing.NewUserRealm(creator))
	id, err := CreatePoll(cross(cur), question, options)
	if err != nil {
		t.Fatalf("CreatePoll failed: %v", err)
	}
	return id
}

func voteAs(cur realm, t *testing.T, voter address, pollID int, optionIndex int) error {
	testing.SetRealm(testing.NewUserRealm(voter))
	return Vote(cross(cur), pollID, optionIndex)
}

func closeAs(cur realm, t *testing.T, closer address, pollID int) error {
	testing.SetRealm(testing.NewUserRealm(closer))
	return ClosePoll(cross(cur), pollID)
}

func TestCreatePoll(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	if id != 0 {
		t.Fatalf("expected first poll id 0, got %d", id)
	}
	if PollCount() != 1 {
		t.Fatalf("expected 1 poll, got %d", PollCount())
	}
	question, options, creator, closed, err := GetPoll(id)
	if err != nil {
		t.Fatalf("GetPoll failed: %v", err)
	}
	if question != "Best Gno project?" {
		t.Fatalf("unexpected question: %q", question)
	}
	if len(options) != 3 || options[0] != "Poll" || options[2] != "Bounty" {
		t.Fatalf("unexpected options: %v", options)
	}
	if creator != alice() {
		t.Fatalf("expected creator alice, got %s", creator.String())
	}
	if closed {
		t.Fatalf("new poll should be open")
	}
	tally, err := Tally(id)
	if err != nil {
		t.Fatalf("Tally failed: %v", err)
	}
	for i, v := range tally {
		if v != 0 {
			t.Fatalf("expected 0 votes for option %d, got %d", i, v)
		}
	}
}

func TestCreatePollValidation(cur realm, t *testing.T) {
	reset()
	if _, err := createPollAsExpectErr(cur, t, alice(), "", "A|B"); err == nil {
		t.Fatalf("expected error for empty question")
	}
	if _, err := createPollAsExpectErr(cur, t, alice(), "Q?", "Only one"); err == nil {
		t.Fatalf("expected error for a single option")
	}
	if _, err := createPollAsExpectErr(cur, t, alice(), "Q?", "A|"); err == nil {
		t.Fatalf("expected error for an empty option")
	}
	if PollCount() != 0 {
		t.Fatalf("expected 0 polls after rejected creates, got %d", PollCount())
	}
}

// createPollAsExpectErr is createPollAs for cases that must fail: it returns
// the error instead of failing the test.
func createPollAsExpectErr(cur realm, t *testing.T, creator address, question string, options string) (int, error) {
	testing.SetRealm(testing.NewUserRealm(creator))
	return CreatePoll(cross(cur), question, options)
}

func TestVoteValid(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	if err := voteAs(cur, t, bob(), id, 0); err != nil {
		t.Fatalf("bob vote failed: %v", err)
	}
	if err := voteAs(cur, t, carol(), id, 1); err != nil {
		t.Fatalf("carol vote failed: %v", err)
	}
	if err := voteAs(cur, t, alice(), id, 0); err != nil {
		t.Fatalf("alice vote failed: %v", err)
	}
	tally, err := Tally(id)
	if err != nil {
		t.Fatalf("Tally failed: %v", err)
	}
	if len(tally) != 3 || tally[0] != 2 || tally[1] != 1 || tally[2] != 0 {
		t.Fatalf("unexpected tally: %v", tally)
	}
}

func TestVoteDuplicateRejected(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	if err := voteAs(cur, t, bob(), id, 0); err != nil {
		t.Fatalf("first vote failed: %v", err)
	}
	if err := voteAs(cur, t, bob(), id, 1); err == nil {
		t.Fatalf("expected error for second vote from the same address")
	}
	tally, _ := Tally(id)
	if tally[0] != 1 || tally[1] != 0 {
		t.Fatalf("duplicate vote changed tally: %v", tally)
	}
}

func TestVoteInvalidOptionRejected(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	if err := voteAs(cur, t, bob(), id, -1); err == nil {
		t.Fatalf("expected error for option index -1")
	}
	if err := voteAs(cur, t, bob(), id, 3); err == nil {
		t.Fatalf("expected error for option index 3 (only 3 options)")
	}
	if err := voteAs(cur, t, bob(), 99, 0); err == nil {
		t.Fatalf("expected error for unknown poll id")
	}
	tally, _ := Tally(id)
	for i, v := range tally {
		if v != 0 {
			t.Fatalf("rejected votes changed tally: option %d has %d", i, v)
		}
	}
}

func TestClosePollThenVoteRejected(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	// Only the creator may close.
	if err := closeAs(cur, t, bob(), id); err == nil {
		t.Fatalf("expected error when non-creator closes the poll")
	}
	// Creator closes it.
	if err := closeAs(cur, t, alice(), id); err != nil {
		t.Fatalf("creator close failed: %v", err)
	}
	if err := closeAs(cur, t, alice(), id); err == nil {
		t.Fatalf("expected error when closing an already-closed poll")
	}
	// Votes after close are rejected.
	if err := voteAs(cur, t, bob(), id, 0); err == nil {
		t.Fatalf("expected error when voting on a closed poll")
	}
	_, _, _, closed, err := GetPoll(id)
	if err != nil {
		t.Fatalf("GetPoll failed: %v", err)
	}
	if !closed {
		t.Fatalf("poll should be closed")
	}
}

func TestRender(cur realm, t *testing.T) {
	reset()
	id := createPollAs(cur, t, alice(), "Best Gno project?", "Poll|Token|Bounty")
	if err := voteAs(cur, t, bob(), id, 2); err != nil {
		t.Fatalf("vote failed: %v", err)
	}
	got := Render("")
	if !strings.Contains(got, "Best Gno project?") {
		t.Fatalf("render missing question: %s", got)
	}
	if !strings.Contains(got, "Bounty: 1 vote(s)") {
		t.Fatalf("render missing tally: %s", got)
	}
	if !strings.Contains(got, "(open)") {
		t.Fatalf("render missing open status: %s", got)
	}
}

func TestRenderEscapesUserInput(cur realm, t *testing.T) {
	reset()
	evil := "[x](javascript:alert(1)) > quote"
	createPollAs(cur, t, alice(), evil, "A|B")
	got := Render("")
	if strings.Contains(got, "[x](javascript") {
		t.Fatalf("render leaked a live markdown link: %s", got)
	}
}
