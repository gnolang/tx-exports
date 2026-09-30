package chess

// Board represents an 8x8 chess board matrix
type Board [8][8]string

// CastlingRights tracks whether king or rooks have moved
type CastlingRights struct {
	WhiteKingMoved      bool
	WhiteLeftRookMoved  bool
	WhiteRightRookMoved bool
	BlackKingMoved      bool
	BlackLeftRookMoved  bool
	BlackRightRookMoved bool
}

// NewInitialBoard returns the standard starting position for a chess game
func NewInitialBoard() Board {
	var b Board

	// Row 0 & 1: Black pieces (lowercase)
	b[0] = [8]string{"r", "n", "b", "q", "k", "b", "n", "r"}
	b[1] = [8]string{"p", "p", "p", "p", "p", "p", "p", "p"}

	// Row 2 to 5: Empty squares
	for i := 2; i < 6; i++ {
		b[i] = [8]string{".", ".", ".", ".", ".", ".", ".", "."}
	}

	// Row 6 & 7: White pieces (uppercase)
	b[6] = [8]string{"P", "P", "P", "P", "P", "P", "P", "P"}
	b[7] = [8]string{"R", "N", "B", "Q", "K", "B", "N", "R"}

	return b
}

// GetPieceEmoji converts a piece character string to a unicode chess emoji
func GetPieceEmoji(p string) string {
	switch p {
	// White pieces
	case "R": return "♖"
	case "N": return "♘"
	case "B": return "♗"
	case "Q": return "♕"
	case "K": return "♔"
	case "P": return "♙"
	// Black pieces
	case "r": return "♜"
	case "n": return "♞"
	case "b": return "♝"
	case "q": return "♛"
	case "k": return "♚"
	case "p": return "♟"
	default: return " " // Empty square
	}
}

// IsWhitePiece returns true if the piece belongs to White
func IsWhitePiece(p string) bool {
	return p >= "A" && p <= "Z"
}

// IsBlackPiece returns true if the piece belongs to Black
func IsBlackPiece(p string) bool {
	return p >= "a" && p <= "z"
}

// Abs returns the absolute value of an integer
func Abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
