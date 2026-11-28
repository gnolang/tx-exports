package tavernquestboard

import (
	"testing"

	"chain"
	"chain/banker"
)

var (
	testPoster = address("g1crdspgq7fctwk7aer7nwdyhtv9el9cqc9xffw5")
	testTaker  = address("g1lp5qjk60ysdgampph8x3ef6d58grftvngd5tvq")
)

func resetState() {
	quests = nil
	escrowTotal = 0
	completed = make(map[address]int)
	earned = make(map[address]int64)
}

func TestQuestLifecycle(cur realm, t *testing.T) {
	resetState()
	realmAddr := cur.Address()

	// Poster membuat quest dengan escrow 1000 ugnot.
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	testing.SetRealm(testing.NewUserRealm(testPoster))
	id := PostQuest(cross(cur), "Bersihkan gudang tavern", "Sapu lantai dan rapikan tong bir")
	if id != 1 {
		t.Fatalf("quest id = %d, want 1", id)
	}
	if EscrowTotal() != 1000 {
		t.Fatalf("escrow = %d, want 1000", EscrowTotal())
	}

	// Adventurer mengambil quest + kirim bukti.
	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(testTaker))
	TakeQuest(cross(cur), id)
	SubmitProof(cross(cur), id, "https://example.com/bukti-foto")

	// Poster approve -> reward cair ke adventurer.
	testing.SetRealm(testing.NewUserRealm(testPoster))
	ApproveQuest(cross(cur), id)

	bnk := banker.NewReadonlyBanker()
	if got := bnk.GetCoin(testTaker, "ugnot"); got != 1000 {
		t.Fatalf("taker balance = %d, want 1000", got)
	}
	if EscrowTotal() != 0 {
		t.Fatalf("escrow after payout = %d, want 0", EscrowTotal())
	}
	if completed[testTaker] != 1 || earned[testTaker] != 1000 {
		t.Fatalf("leaderboard taker = %d quests / %d earned, want 1 / 1000",
			completed[testTaker], earned[testTaker])
	}
	if quests[0].Status != statusDone {
		t.Fatalf("quest status = %s, want done", quests[0].Status)
	}
}

func TestCancelRefundsPoster(cur realm, t *testing.T) {
	resetState()
	realmAddr := cur.Address()

	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 500)))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500)))
	testing.SetRealm(testing.NewUserRealm(testPoster))
	id := PostQuest(cross(cur), "Quest batal", "akan dibatalkan")
	CancelQuest(cross(cur), id)

	bnk := banker.NewReadonlyBanker()
	if got := bnk.GetCoin(testPoster, "ugnot"); got != 500 {
		t.Fatalf("poster balance after refund = %d, want 500", got)
	}
	if EscrowTotal() != 0 {
		t.Fatalf("escrow after cancel = %d, want 0", EscrowTotal())
	}
}

func TestRejectThenResubmit(cur realm, t *testing.T) {
	resetState()
	realmAddr := cur.Address()

	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 300)))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 300)))
	testing.SetRealm(testing.NewUserRealm(testPoster))
	id := PostQuest(cross(cur), "Quest tolak bukti", "bukti pertama ditolak")

	testing.SetOriginSend(chain.NewCoins())
	testing.SetRealm(testing.NewUserRealm(testTaker))
	TakeQuest(cross(cur), id)
	SubmitProof(cross(cur), id, "bukti kurang jelas")

	testing.SetRealm(testing.NewUserRealm(testPoster))
	RejectProof(cross(cur), id)
	if quests[0].Status != statusTaken {
		t.Fatalf("status after reject = %s, want taken", quests[0].Status)
	}

	testing.SetRealm(testing.NewUserRealm(testTaker))
	SubmitProof(cross(cur), id, "https://example.com/bukti-baru")

	testing.SetRealm(testing.NewUserRealm(testPoster))
	ApproveQuest(cross(cur), id)
	if quests[0].Status != statusDone {
		t.Fatalf("status after second approve = %s, want done", quests[0].Status)
	}
}

func TestRender(t *testing.T) {
	resetState()
	board := Render("")
	if board == "" {
		t.Fatalf("empty board render")
	}
	lb := Render("leaderboard")
	if lb == "" {
		t.Fatalf("empty leaderboard render")
	}
}
