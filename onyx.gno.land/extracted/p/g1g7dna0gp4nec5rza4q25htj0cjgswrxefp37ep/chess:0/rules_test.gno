package chess

import (
	"testing"
)

func TestNewInitialBoard(t *testing.T) {
	b := NewInitialBoard()

	// Check White Backrank
	if b[7][4] != "K" || b[7][3] != "Q" {
		t.Fatalf("unexpected white backrank: %v", b[7])
	}
	// Check Black Backrank
	if b[0][4] != "k" || b[0][3] != "q" {
		t.Fatalf("unexpected black backrank: %v", b[0])
	}
	// Check Pawns
	for c := 0; c < 8; c++ {
		if b[6][c] != "P" {
			t.Fatalf("expected white pawn at (6,%d), got %s", c, b[6][c])
		}
		if b[1][c] != "p" {
			t.Fatalf("expected black pawn at (1,%d), got %s", c, b[1][c])
		}
	}
}

func TestPieceMoveValidations(t *testing.T) {
	b := NewInitialBoard()
	var rights CastlingRights

	// 1. Pawn e2-e4 (from 6,4 to 4,4) is valid
	if !IsValidMove(b, 6, 4, 4, 4, true, rights, -1) {
		t.Fatal("e2-e4 pawn move should be valid")
	}

	// 2. Knight b1-c3 (from 7,1 to 5,2) is valid
	if !IsValidMove(b, 7, 1, 5, 2, true, rights, -1) {
		t.Fatal("knight b1-c3 move should be valid")
	}

	// 3. Bishop c1-e3 should be blocked initially by pawns
	if IsValidMove(b, 7, 2, 5, 4, true, rights, -1) {
		t.Fatal("bishop cannot jump over pawns")
	}
}

func TestPromotionNormalization(t *testing.T) {
	// White default promotion
	p, err := NormalizePromotionPiece("", true)
	if err != nil || p != "Q" {
		t.Fatalf("expected 'Q', got %s, err: %v", p, err)
	}

	// Black knight promotion
	p, err = NormalizePromotionPiece("n", false)
	if err != nil || p != "n" {
		t.Fatalf("expected 'n', got %s, err: %v", p, err)
	}

	// Invalid piece
	_, err = NormalizePromotionPiece("K", true)
	if err == nil {
		t.Fatal("expected error for invalid promotion to King")
	}
}

func TestReplayUCI(t *testing.T) {
	// 1. Scholar's Mate -> White checkmates Black
	scholarsMate := "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7"
	_, _, status, err := ReplayUCI(scholarsMate)
	if err != nil {
		t.Fatalf("unexpected error replaying scholar's mate: %v", err)
	}
	if status != "WHITE_WON" {
		t.Fatalf("expected status WHITE_WON, got %s", status)
	}

	// 2. Fool's Mate -> Black checkmates White in 2 moves
	foolsMate := "f2f3 e7e5 g2g4 d8h4"
	_, _, status, err = ReplayUCI(foolsMate)
	if err != nil {
		t.Fatalf("unexpected error replaying fool's mate: %v", err)
	}
	if status != "BLACK_WON" {
		t.Fatalf("expected status BLACK_WON, got %s", status)
	}

	// 3. Ongoing game -> status PLAYING
	ongoing := "e2e4 e7e5 g1f3"
	_, _, status, err = ReplayUCI(ongoing)
	if err != nil {
		t.Fatalf("unexpected error replaying ongoing game: %v", err)
	}
	if status != "PLAYING" {
		t.Fatalf("expected status PLAYING, got %s", status)
	}

	// 4. Illegal move -> returns error
	illegal := "e2e5"
	_, _, _, err = ReplayUCI(illegal)
	if err == nil {
		t.Fatal("expected error for illegal move e2e5")
	}
}

