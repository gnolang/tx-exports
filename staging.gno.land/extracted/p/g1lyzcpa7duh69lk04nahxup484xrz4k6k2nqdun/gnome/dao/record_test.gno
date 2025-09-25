package dao

import (
	"testing"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

func TestVotingRecord(t *testing.T) {
	// Act
	record := NewVotingRecord()

	// Assert
	if got := record.Votes(); got != nil {
		t.Fatalf("expected no votes, got: %d", len(got))
	}

	if got := record.VoteCount(); got != 0 {
		t.Fatalf("expected no vote count: 0, got: %d", got)
	}
}

func TestVotingRecordAdd(t *testing.T) {
	// Arrange
	record := NewVotingRecord()
	vote := gnome.Vote{Choice: gnome.ChoiceYes}

	// Act
	record.Add(vote)

	// Assert
	votes := record.Votes()
	if c := len(votes); c != 1 {
		t.Fatalf("expected one votes, got: %d", c)
	}

	if got := votes[0]; got != vote {
		t.Fatalf("expected vote: %v, got: %v", vote, got)
	}

	if got := record.VoteCount(); got != 1 {
		t.Fatalf("expected vote count: %d, got: %d", 1, got)
	}

	if got := record.Get(vote.Choice); got != 1 {
		t.Fatalf("expected record to get one '%v' count, got: %d", gnome.ChoiceYes, got)
	}

	record.Iterate(func(v gnome.VoteChoice, count uint) bool {
		if v != gnome.ChoiceYes {
			t.Fatalf("expected iterate choice: %v, got: %v", gnome.ChoiceYes, v)
		}

		if count != 1 {
			t.Fatalf("expected iterate vote count: %d, got: %d", 1, count)
		}

		return false
	})
}

func TestVotingRecordRemove(t *testing.T) {
	t.Skip("TODO: Write unit test for VotingRecord.Remove()")
}

func TestSelectChoiceByMajority(t *testing.T) {
	t.Skip("TODO: Write unit test for SelectChoiceByMajority")
}

func TestSelectChoiceBySuperMajority(t *testing.T) {
	t.Skip("TODO: Write unit test for SelectChoiceBySuperMajority")
}

func TestSelectChoiceByPlurality(t *testing.T) {
	t.Skip("TODO: Write unit test for SelectChoiceByPlurality")
}
