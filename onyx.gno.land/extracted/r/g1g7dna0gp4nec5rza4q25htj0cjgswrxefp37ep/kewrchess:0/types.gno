package kewrchess

import (
	"gno.land/p/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/chess"
)

// Game represents an on-chain chess game session
type Game struct {
	id            int
	white         address              // Wallet address of White player
	black         address              // Wallet address of Black player
	board         chess.Board          // 8x8 chess board from package chess
	isWhiteTurn   bool                 // True = White's turn, False = Black's turn
	status        string               // "PLAYING", "WHITE_WON", "BLACK_WON", "DRAW"
	castling      chess.CastlingRights // Castling rights for White & Black
	enPassantCol  int                  // Pawn column vulnerable to en passant (-1 if none)
	drawOfferedBy address              // Address of player offering a draw ("" if none)
	resignedBy        address              // Address of player who resigned ("" if none)
	settledBy         address              // Address of player who recorded final settlement on blockchain ("" if not yet)

	// Anti-Cheat Protection: Proposal & Challenge Period
	proposedBy        address              // Player submitting victory claim
	pendingStatus     string               // Proposed settlement status ("WHITE_WON", "BLACK_WON", "DRAW")
	challengeDeadline int64                // Unix timestamp deadline for challenging settlement proposal
	
	// Anti-RageQuit Protection: Timeout & Abandonment
	turnDeadline      int64                // Unix timestamp deadline for opponent's turn response
	turnChallengedBy  address              // Player demanding turn response due to AFK opponent
}

// NewGame initializes a new game with the standard chess starting layout
func NewGame(id int, white, black address) *Game {
	return &Game{
		id:                id,
		white:             white,
		black:             black,
		board:             chess.NewInitialBoard(),
		isWhiteTurn:       true,
		status:            "PLAYING",
		castling:          chess.CastlingRights{},
		enPassantCol:      -1,
		drawOfferedBy:     "",
		resignedBy:        "",
		settledBy:         "",
		proposedBy:        "",
		pendingStatus:     "",
		challengeDeadline: 0,
		turnDeadline:      0,
		turnChallengedBy:  "",
	}
}
