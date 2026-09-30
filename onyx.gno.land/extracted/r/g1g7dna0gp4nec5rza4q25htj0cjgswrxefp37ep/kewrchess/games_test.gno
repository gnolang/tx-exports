package kewrchess

import (
	"testing"
)

func TestGameInitAndRender(t *testing.T) {
	if GetGamesCount() != 1 {
		t.Fatalf("expected 1 game in init, got %d", GetGamesCount())
	}

	rendered := Render("")
	if len(rendered) == 0 {
		t.Fatal("rendered output is empty")
	}
}

func TestResign(t *testing.T) {
	white := GetWhitePlayer(0)
	err := Resign(white, 0)
	if err != nil {
		t.Fatalf("unexpected error on resign: %v", err)
	}

	if GetGameStatus(0) != "BLACK_WON" {
		t.Fatalf("expected status BLACK_WON, got %s", GetGameStatus(0))
	}
}

func TestNewGameAndMoves(t *testing.T) {
	p1 := address("g1p177777777777777777777777777777777777777")
	p2 := address("g1p277777777777777777777777777777777777777")

	err := CreateGame(p1, p2)
	if err != nil {
		t.Fatalf("failed to create game: %v", err)
	}

	gameID := GetGamesCount() - 1

	// White moves pawn e2 to e4 (from 6,4 to 4,4)
	err = MakeMove(p1, gameID, 6, 4, 4, 4)
	if err != nil {
		t.Fatalf("failed to make move e2e4: %v", err)
	}

	if IsWhiteTurn(gameID) {
		t.Fatal("expected Black's turn after White move")
	}

	// Black moves pawn e7 to e5 (from 1,4 to 3,4)
	err = MakeMove(p2, gameID, 1, 4, 3, 4)
	if err != nil {
		t.Fatalf("failed to make move e7e5: %v", err)
	}

	// Test draw offer
	err = OfferDraw(p1, gameID)
	if err != nil {
		t.Fatalf("p1 failed to offer draw: %v", err)
	}

	if GetDrawOfferedBy(gameID) != p1 {
		t.Fatalf("expected draw offered by p1, got %s", GetDrawOfferedBy(gameID))
	}

	// p2 accepts draw
	err = AcceptDraw(p2, gameID)
	if err != nil {
		t.Fatalf("p2 failed to accept draw: %v", err)
	}

	if GetGameStatus(gameID) != "DRAW" {
		t.Fatalf("expected status DRAW, got %s", GetGameStatus(gameID))
	}
}

func TestMatchmakingQueue(t *testing.T) {
	p1 := address("g1player11111111111111111111111111111111111")
	p2 := address("g1player22222222222222222222222222222222222")

	// 1. Initial queue count must be 0
	if GetQueueCount() != 0 {
		t.Fatalf("expected queue count 0, got %d", GetQueueCount())
	}

	// 2. Player 1 joins queue
	err := JoinQueue(p1)
	if err != nil {
		t.Fatalf("p1 failed to join queue: %v", err)
	}

	if GetQueueCount() != 1 {
		t.Fatalf("expected queue count 1, got %d", GetQueueCount())
	}
	if !IsInQueue(p1) {
		t.Fatal("expected p1 to be in queue")
	}

	// 3. Joining twice must be rejected
	err = JoinQueue(p1)
	if err == nil {
		t.Fatal("expected error when joining queue twice")
	}

	// 4. Test LeaveQueue
	err = LeaveQueue(p1)
	if err != nil {
		t.Fatalf("p1 failed to leave queue: %v", err)
	}
	if GetQueueCount() != 0 {
		t.Fatalf("expected queue count 0 after leave, got %d", GetQueueCount())
	}
	if IsInQueue(p1) {
		t.Fatal("expected p1 to not be in queue after leave")
	}

	// 5. Leaving when not in queue should return an error
	err = LeaveQueue(p1)
	if err == nil {
		t.Fatal("expected error when leaving queue while not in it")
	}

	// 6. Test Matchmaking: P1 joins, then P2 joins -> match automatically created
	initialGameCount := GetGamesCount()
	err = JoinQueue(p1)
	if err != nil {
		t.Fatalf("p1 failed to rejoin queue: %v", err)
	}

	err = JoinQueue(p2)
	if err != nil {
		t.Fatalf("p2 failed to join queue: %v", err)
	}

	// Queue should be empty again after matching
	if GetQueueCount() != 0 {
		t.Fatalf("expected queue count 0 after match, got %d", GetQueueCount())
	}

	// New game should be created
	if GetGamesCount() != initialGameCount+1 {
		t.Fatalf("expected game count %d, got %d", initialGameCount+1, GetGamesCount())
	}

	newGameID := GetGamesCount() - 1
	if GetWhitePlayer(newGameID) != p1 {
		t.Fatalf("expected White to be p1, got %s", GetWhitePlayer(newGameID))
	}
	if GetBlackPlayer(newGameID) != p2 {
		t.Fatalf("expected Black to be p2, got %s", GetBlackPlayer(newGameID))
	}
	if GetGameStatus(newGameID) != "PLAYING" {
		t.Fatalf("expected status PLAYING, got %s", GetGameStatus(newGameID))
	}

	// Verify GetActiveGameForPlayer
	if GetActiveGameForPlayer(p1) != newGameID {
		t.Fatalf("expected active game for p1 to be %d, got %d", newGameID, GetActiveGameForPlayer(p1))
	}
	if GetActiveGameForPlayer(p2) != newGameID {
		t.Fatalf("expected active game for p2 to be %d, got %d", newGameID, GetActiveGameForPlayer(p2))
	}
}

func TestSettleGame(t *testing.T) {
	// For testing instant auto-settlement
	oldWindow := ChallengeWindowSeconds
	ChallengeWindowSeconds = 0
	defer func() { ChallengeWindowSeconds = oldWindow }()

	p1 := address("g1winner111111111111111111111111111111111")
	p2 := address("g1loser2222222222222222222222222222222222")

	err := CreateGame(p1, p2)
	if err != nil {
		t.Fatalf("failed to create game: %v", err)
	}

	gameID := GetGamesCount() - 1
	scholarsMate := "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7"

	// 1. Third party caller should not be able to settle
	p3 := address("g1intruder3333333333333333333333333333333")
	err = SettleGame(p3, gameID, scholarsMate)
	if err == nil {
		t.Fatal("expected error when non-player tries to settle")
	}

	// 2. Incomplete game (not checkmate) should fail
	err = SettleGame(p1, gameID, "e2e4 e7e5")
	if err == nil {
		t.Fatal("expected error when moves do not end in checkmate or draw")
	}

	// 3. Illegal move sequence should fail
	err = SettleGame(p1, gameID, "e2e5")
	if err == nil {
		t.Fatal("expected error for illegal move sequence")
	}

	// 4. White won checkmate, but Black tries to claim
	err = SettleGame(p2, gameID, scholarsMate)
	if err == nil {
		t.Fatal("expected error when losing player tries to claim victory")
	}

	// 5. Legitimate Winner (p1 / White) settles with valid Scholar's Mate checkmate
	err = SettleGame(p1, gameID, scholarsMate)
	if err != nil {
		t.Fatalf("failed to settle game: %v", err)
	}

	if GetGameStatus(gameID) != "WHITE_WON" {
		t.Fatalf("expected status WHITE_WON, got %s", GetGameStatus(gameID))
	}

	if GetSettledBy(gameID) != p1 {
		t.Fatalf("expected settledBy p1, got %s", GetSettledBy(gameID))
	}

	// 6. Settling again should fail
	err = SettleGame(p1, gameID, scholarsMate)
	if err == nil {
		t.Fatal("expected error when trying to settle already settled game")
	}
}

func TestTwoPhaseSettlementAndDispute(t *testing.T) {
	p1 := address("g1proposer111111111111111111111111111111")
	p2 := address("g1victim22222222222222222222222222222222")

	err := CreateGame(p1, p2)
	if err != nil {
		t.Fatalf("failed to create game: %v", err)
	}

	gameID := GetGamesCount() - 1
	scholarsMate := "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7"

	// 1. Proposer submits settlement proposal
	err = ProposeSettlement(p1, gameID, scholarsMate)
	if err != nil {
		t.Fatalf("p1 failed to propose settlement: %v", err)
	}

	if GetGameStatus(gameID) != "PROPOSED" {
		t.Fatalf("expected status PROPOSED, got %s", GetGameStatus(gameID))
	}
	if GetProposedBy(gameID) != p1 {
		t.Fatalf("expected proposedBy p1, got %s", GetProposedBy(gameID))
	}

	// 2. Proposer cannot confirm their own proposal
	err = ConfirmSettlement(p1, gameID)
	if err == nil {
		t.Fatal("expected error when proposer tries to confirm their own proposal")
	}

	// 3. Victim disputes fraudulent proposal -> status reverts to PLAYING
	err = DisputeSettlement(p2, gameID)
	if err != nil {
		t.Fatalf("victim failed to dispute proposal: %v", err)
	}

	if GetGameStatus(gameID) != "PLAYING" {
		t.Fatalf("expected status PLAYING after dispute, got %s", GetGameStatus(gameID))
	}
	if GetProposedBy(gameID) != "" {
		t.Fatal("expected proposedBy to be cleared after dispute")
	}

	// 4. Repropose and victim legitimately confirms -> instant settlement
	err = ProposeSettlement(p1, gameID, scholarsMate)
	if err != nil {
		t.Fatalf("failed to repropose settlement: %v", err)
	}

	err = ConfirmSettlement(p2, gameID)
	if err != nil {
		t.Fatalf("victim failed to confirm settlement: %v", err)
	}

	if GetGameStatus(gameID) != "WHITE_WON" {
		t.Fatalf("expected status WHITE_WON after confirmation, got %s", GetGameStatus(gameID))
	}
}

func TestTurnTimeoutAbandonment(t *testing.T) {
	oldTimeout := TurnTimeoutSeconds
	TurnTimeoutSeconds = 0
	defer func() { TurnTimeoutSeconds = oldTimeout }()

	p1 := address("g1activeplayer11111111111111111111111111")
	p2 := address("g1ragequitter22222222222222222222222222")

	err := CreateGame(p1, p2)
	if err != nil {
		t.Fatalf("failed to create game: %v", err)
	}

	gameID := GetGamesCount() - 1

	// White played e2e4 offchain, Black rage-quitted on move 1!
	currentMoves := "e2e4"

	// 1. Black cannot start turn timer when it is Black's turn
	err = StartTurnTimer(p2, gameID, currentMoves)
	if err == nil {
		t.Fatal("expected error when AFK player tries to start timer against opponent")
	}

	// 2. White legitimately starts turn timer for AFK Black
	err = StartTurnTimer(p1, gameID, currentMoves)
	if err != nil {
		t.Fatalf("white failed to start turn timer: %v", err)
	}

	if GetTurnChallengedBy(gameID) != p1 {
		t.Fatalf("expected turnChallengedBy p1, got %s", GetTurnChallengedBy(gameID))
	}

	// 3. Other player or Black cannot claim timeout
	err = ClaimTimeout(p2, gameID)
	if err == nil {
		t.Fatal("expected error when non-challenger tries to claim timeout")
	}

	// 4. White claims timeout (since TurnTimeoutSeconds=0) -> White wins by Abandonment!
	err = ClaimTimeout(p1, gameID)
	if err != nil {
		t.Fatalf("white failed to claim timeout: %v", err)
	}

	if GetGameStatus(gameID) != "WHITE_WON" {
		t.Fatalf("expected status WHITE_WON from abandonment, got %s", GetGameStatus(gameID))
	}
	if GetSettledBy(gameID) != p1 {
		t.Fatalf("expected settledBy p1, got %s", GetSettledBy(gameID))
	}
}


