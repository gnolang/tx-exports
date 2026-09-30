package chess

import (
	"errors"
)

// IsPathClear checks if all squares between from and to (exclusive) are empty
func IsPathClear(board Board, fromRow, fromCol, toRow, toCol int) bool {
	dRow := toRow - fromRow
	dCol := toCol - fromCol

	stepRow := 0
	if dRow > 0 {
		stepRow = 1
	} else if dRow < 0 {
		stepRow = -1
	}

	stepCol := 0
	if dCol > 0 {
		stepCol = 1
	} else if dCol < 0 {
		stepCol = -1
	}

	currRow := fromRow + stepRow
	currCol := fromCol + stepCol

	for currRow != toRow || currCol != toCol {
		if board[currRow][currCol] != "." {
			return false
		}
		currRow += stepRow
		currCol += stepCol
	}
	return true
}

// IsOpponentOrEmpty checks if destination square is empty or has an opponent piece
func IsOpponentOrEmpty(board Board, toRow, toCol int, isWhite bool) bool {
	dest := board[toRow][toCol]
	if dest == "." {
		return true
	}
	destIsWhite := IsWhitePiece(dest)
	return isWhite != destIsWhite
}

// IsKingInCheck checks if the king of the specified color is under attack
func IsKingInCheck(board Board, isWhite bool) bool {
	kingRow := -1
	kingCol := -1
	kingChar := "k"
	if isWhite {
		kingChar = "K"
	}

	for r := 0; r < 8; r++ {
		for c := 0; c < 8; c++ {
			if board[r][c] == kingChar {
				kingRow = r
				kingCol = c
				break
			}
		}
		if kingRow != -1 {
			break
		}
	}

	if kingRow == -1 {
		return false
	}

	for r := 0; r < 8; r++ {
		for c := 0; c < 8; c++ {
			piece := board[r][c]
			if piece == "." {
				continue
			}
			pieceIsWhite := IsWhitePiece(piece)
			if pieceIsWhite == isWhite {
				continue
			}

			canAttack := false
			switch piece {
			case "P", "p":
				dRow := kingRow - r
				dCol := kingCol - c
				if pieceIsWhite {
					canAttack = (dRow == -1 && (dCol == 1 || dCol == -1))
				} else {
					canAttack = (dRow == 1 && (dCol == 1 || dCol == -1))
				}
			case "N", "n":
				canAttack = IsValidKnightMove(r, c, kingRow, kingCol)
			case "B", "b":
				canAttack = IsValidBishopMove(board, r, c, kingRow, kingCol)
			case "R", "r":
				canAttack = IsValidRookMove(board, r, c, kingRow, kingCol)
			case "Q", "q":
				canAttack = IsValidQueenMove(board, r, c, kingRow, kingCol)
			case "K", "k":
				dRow := Abs(kingRow - r)
				dCol := Abs(kingCol - c)
				canAttack = (dRow <= 1 && dCol <= 1)
			}

			if canAttack {
				return true
			}
		}
	}
	return false
}

// HasAnyLegalMoves checks if the current player has at least one legal move
func HasAnyLegalMoves(board Board, isWhite bool, rights CastlingRights, enPassantCol int) bool {
	for r := 0; r < 8; r++ {
		for c := 0; c < 8; c++ {
			piece := board[r][c]
			if piece == "." {
				continue
			}
			pieceIsWhite := IsWhitePiece(piece)
			if pieceIsWhite != isWhite {
				continue
			}

			for tr := 0; tr < 8; tr++ {
				for tc := 0; tc < 8; tc++ {
					if IsValidMove(board, r, c, tr, tc, isWhite, rights, enPassantCol) {
						// Simulate move to check if king remains in check
						origDest := board[tr][tc]
						board[tr][tc] = piece
						board[r][c] = "."

						inCheck := IsKingInCheck(board, isWhite)

						board[r][c] = piece
						board[tr][tc] = origDest

						if !inCheck {
							return true
						}
					}
				}
			}
		}
	}
	return false
}

// IsValidPawnMove validates pawn movements including double step and en passant
func IsValidPawnMove(board Board, fromRow, fromCol, toRow, toCol int, isWhite bool, enPassantCol int) bool {
	dRow := toRow - fromRow
	dCol := toCol - fromCol

	if isWhite {
		if dRow == -1 && dCol == 0 {
			return board[toRow][toCol] == "."
		}
		if fromRow == 6 && dRow == -2 && dCol == 0 {
			return board[5][fromCol] == "." && board[4][fromCol] == "."
		}
		if dRow == -1 && (dCol == 1 || dCol == -1) {
			dest := board[toRow][toCol]
			if dest == "." {
				// En Passant capture (must be from row 3 targeting enPassantCol)
				return fromRow == 3 && toCol == enPassantCol
			}
			return !IsWhitePiece(dest)
		}
	} else {
		if dRow == 1 && dCol == 0 {
			return board[toRow][toCol] == "."
		}
		if fromRow == 1 && dRow == 2 && dCol == 0 {
			return board[2][fromCol] == "." && board[3][fromCol] == "."
		}
		if dRow == 1 && (dCol == 1 || dCol == -1) {
			dest := board[toRow][toCol]
			if dest == "." {
				// En Passant capture (must be from row 4 targeting enPassantCol)
				return fromRow == 4 && toCol == enPassantCol
			}
			return IsWhitePiece(dest)
		}
	}
	return false
}

// IsValidKnightMove validates knight L-shaped moves
func IsValidKnightMove(fromRow, fromCol, toRow, toCol int) bool {
	dRow := Abs(toRow - fromRow)
	dCol := Abs(toCol - fromCol)
	return (dRow == 1 && dCol == 2) || (dRow == 2 && dCol == 1)
}

// IsValidBishopMove validates bishop diagonal moves
func IsValidBishopMove(board Board, fromRow, fromCol, toRow, toCol int) bool {
	dRow := Abs(toRow - fromRow)
	dCol := Abs(toCol - fromCol)
	if dRow != dCol {
		return false
	}
	return IsPathClear(board, fromRow, fromCol, toRow, toCol)
}

// IsValidRookMove validates rook straight line moves
func IsValidRookMove(board Board, fromRow, fromCol, toRow, toCol int) bool {
	if fromRow != toRow && fromCol != toCol {
		return false
	}
	return IsPathClear(board, fromRow, fromCol, toRow, toCol)
}

// IsValidQueenMove validates queen diagonal or straight moves
func IsValidQueenMove(board Board, fromRow, fromCol, toRow, toCol int) bool {
	dRow := Abs(toRow - fromRow)
	dCol := Abs(toCol - fromCol)

	isDiagonal := (dRow == dCol)
	isStraight := (fromRow == toRow || fromCol == toCol)

	if !isDiagonal && !isStraight {
		return false
	}
	return IsPathClear(board, fromRow, fromCol, toRow, toCol)
}

// IsValidKingMove validates king standard 1-square moves and castling (O-O and O-O-O)
func IsValidKingMove(board Board, fromRow, fromCol, toRow, toCol int, isWhite bool, rights CastlingRights) bool {
	dRow := Abs(toRow - fromRow)
	dCol := Abs(toCol - fromCol)

	if dRow <= 1 && dCol <= 1 {
		return true
	}

	// Castling
	if dRow == 0 && dCol == 2 {
		if isWhite {
			if rights.WhiteKingMoved {
				return false
			}
			// Kingside Castling (Short O-O)
			if toCol == 6 {
				if rights.WhiteRightRookMoved || board[7][7] != "R" {
					return false
				}
				if board[7][5] != "." || board[7][6] != "." {
					return false
				}
				if IsKingInCheck(board, true) {
					return false
				}
				// Verify intermediate square 7, 5 is not in check
				board[7][4] = "."
				board[7][5] = "K"
				inCheckStep := IsKingInCheck(board, true)
				board[7][5] = "."
				board[7][4] = "K"
				if inCheckStep {
					return false
				}
				return true
			}
			// Queenside Castling (Long O-O-O)
			if toCol == 2 {
				if rights.WhiteLeftRookMoved || board[7][0] != "R" {
					return false
				}
				if board[7][1] != "." || board[7][2] != "." || board[7][3] != "." {
					return false
				}
				if IsKingInCheck(board, true) {
					return false
				}
				// Verify intermediate square 7, 3 is not in check
				board[7][4] = "."
				board[7][3] = "K"
				inCheckStep := IsKingInCheck(board, true)
				board[7][3] = "."
				board[7][4] = "K"
				if inCheckStep {
					return false
				}
				return true
			}
		} else {
			if rights.BlackKingMoved {
				return false
			}
			// Kingside Castling (Short o-o)
			if toCol == 6 {
				if rights.BlackRightRookMoved || board[0][7] != "r" {
					return false
				}
				if board[0][5] != "." || board[0][6] != "." {
					return false
				}
				if IsKingInCheck(board, false) {
					return false
				}
				// Verify intermediate square 0, 5 is not in check
				board[0][4] = "."
				board[0][5] = "k"
				inCheckStep := IsKingInCheck(board, false)
				board[0][5] = "."
				board[0][4] = "k"
				if inCheckStep {
					return false
				}
				return true
			}
			// Queenside Castling (Long o-o-o)
			if toCol == 2 {
				if rights.BlackLeftRookMoved || board[0][0] != "r" {
					return false
				}
				if board[0][1] != "." || board[0][2] != "." || board[0][3] != "." {
					return false
				}
				if IsKingInCheck(board, false) {
					return false
				}
				// Verify intermediate square 0, 3 is not in check
				board[0][4] = "."
				board[0][3] = "k"
				inCheckStep := IsKingInCheck(board, false)
				board[0][3] = "."
				board[0][4] = "k"
				if inCheckStep {
					return false
				}
				return true
			}
		}
	}
	return false
}

// IsValidMove checks if a move from (fromRow, fromCol) to (toRow, toCol) is valid
func IsValidMove(board Board, fromRow, fromCol, toRow, toCol int, isWhiteTurn bool, rights CastlingRights, enPassantCol int) bool {
	piece := board[fromRow][fromCol]
	if piece == "." {
		return false
	}

	isWhite := IsWhitePiece(piece)
	if isWhite != isWhiteTurn {
		return false
	}

	if !IsOpponentOrEmpty(board, toRow, toCol, isWhite) {
		return false
	}

	switch piece {
	case "P", "p":
		return IsValidPawnMove(board, fromRow, fromCol, toRow, toCol, isWhite, enPassantCol)
	case "N", "n":
		return IsValidKnightMove(fromRow, fromCol, toRow, toCol)
	case "B", "b":
		return IsValidBishopMove(board, fromRow, fromCol, toRow, toCol)
	case "R", "r":
		return IsValidRookMove(board, fromRow, fromCol, toRow, toCol)
	case "Q", "q":
		return IsValidQueenMove(board, fromRow, fromCol, toRow, toCol)
	case "K", "k":
		return IsValidKingMove(board, fromRow, fromCol, toRow, toCol, isWhite, rights)
	}

	return false
}

// NormalizePromotionPiece validates and normalizes the promotion piece symbol
func NormalizePromotionPiece(promo string, isWhite bool) (string, error) {
	switch promo {
	case "Q", "q", "":
		if isWhite {
			return "Q", nil
		}
		return "q", nil
	case "R", "r":
		if isWhite {
			return "R", nil
		}
		return "r", nil
	case "B", "b":
		if isWhite {
			return "B", nil
		}
		return "b", nil
	case "N", "n":
		if isWhite {
			return "N", nil
		}
		return "n", nil
	default:
		return "", errors.New("pilihan promosi tidak valid: gunakan Q (Queen), R (Rook), B (Bishop), atau N (Knight)")
	}
}

func splitWords(s string) []string {
	var words []string
	var cur []byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',' {
			if len(cur) > 0 {
				words = append(words, string(cur))
				cur = nil
			}
		} else {
			cur = append(cur, c)
		}
	}
	if len(cur) > 0 {
		words = append(words, string(cur))
	}
	return words
}

// ParseUCIMove parses a standard UCI move string (e.g. "e2e4", "e7e8q")
func ParseUCIMove(uci string) (fromRow, fromCol, toRow, toCol int, promoPiece string, err error) {
	if len(uci) < 4 || len(uci) > 5 {
		return 0, 0, 0, 0, "", errors.New("format langkah UCI harus 4 atau 5 karakter (contoh: e2e4 atau e7e8q)")
	}

	fromFile := uci[0]
	fromRank := uci[1]
	toFile := uci[2]
	toRank := uci[3]

	if fromFile < 'a' || fromFile > 'h' || toFile < 'a' || toFile > 'h' ||
		fromRank < '1' || fromRank > '8' || toRank < '1' || toRank > '8' {
		return 0, 0, 0, 0, "", errors.New("koordinat UCI tidak valid: " + uci)
	}

	fromCol = int(fromFile - 'a')
	fromRow = 8 - int(fromRank - '0')
	toCol = int(toFile - 'a')
	toRow = 8 - int(toRank - '0')

	if len(uci) == 5 {
		promoPiece = string(uci[4])
	}

	return fromRow, fromCol, toRow, toCol, promoPiece, nil
}

// ApplyMove applies a move to the board after validating it, updating castling rights and en passant.
func ApplyMove(board Board, fromRow, fromCol, toRow, toCol int, promoPiece string, isWhiteTurn bool, rights *CastlingRights, enPassantCol *int) (Board, error) {
	if fromRow < 0 || fromRow > 7 || fromCol < 0 || fromCol > 7 ||
		toRow < 0 || toRow > 7 || toCol < 0 || toCol > 7 {
		return board, errors.New("koordinat di luar papan")
	}

	piece := board[fromRow][fromCol]
	if piece == "." {
		return board, errors.New("tidak ada bidak di posisi asal")
	}

	isWhite := IsWhitePiece(piece)
	if isWhite != isWhiteTurn {
		return board, errors.New("bukan giliran warna bidak ini")
	}

	if !IsValidMove(board, fromRow, fromCol, toRow, toCol, isWhiteTurn, *rights, *enPassantCol) {
		return board, errors.New("langkah catur tidak valid")
	}

	isPromotion := (piece == "P" && toRow == 0) || (piece == "p" && toRow == 7)
	finalPiece := piece
	if isPromotion {
		promoted, err := NormalizePromotionPiece(promoPiece, isWhite)
		if err != nil {
			return board, err
		}
		finalPiece = promoted
	}

	isCastling := (piece == "K" || piece == "k") && Abs(toCol-fromCol) == 2
	isEnPassant := (piece == "P" || piece == "p") && toCol == *enPassantCol && fromCol != toCol && board[toRow][toCol] == "."

	// Verify move does not leave own king in check
	origDest := board[toRow][toCol]
	board[toRow][toCol] = piece
	board[fromRow][fromCol] = "."

	var epRow int
	var epPiece string
	if isEnPassant {
		if isWhite {
			epRow = 3
		} else {
			epRow = 4
		}
		epPiece = board[epRow][toCol]
		board[epRow][toCol] = "."
	}

	inCheck := IsKingInCheck(board, isWhite)

	board[fromRow][fromCol] = piece
	board[toRow][toCol] = origDest
	if isEnPassant {
		board[epRow][toCol] = epPiece
	}

	if inCheck {
		return board, errors.New("langkah ilegal: Raja terkena skak")
	}

	// Execute move
	board[toRow][toCol] = finalPiece
	board[fromRow][fromCol] = "."

	if isEnPassant {
		if isWhite {
			board[3][toCol] = "."
		} else {
			board[4][toCol] = "."
		}
	}

	if isCastling {
		if isWhite {
			if toCol == 6 {
				board[7][5] = "R"
				board[7][7] = "."
			} else if toCol == 2 {
				board[7][3] = "R"
				board[7][0] = "."
			}
		} else {
			if toCol == 6 {
				board[0][5] = "r"
				board[0][7] = "."
			} else if toCol == 2 {
				board[0][3] = "r"
				board[0][0] = "."
			}
		}
	}

	// Update castling rights
	if piece == "K" {
		rights.WhiteKingMoved = true
	} else if piece == "k" {
		rights.BlackKingMoved = true
	} else if piece == "R" {
		if fromRow == 7 && fromCol == 0 {
			rights.WhiteLeftRookMoved = true
		} else if fromRow == 7 && fromCol == 7 {
			rights.WhiteRightRookMoved = true
		}
	} else if piece == "r" {
		if fromRow == 0 && fromCol == 0 {
			rights.BlackLeftRookMoved = true
		} else if fromRow == 0 && fromCol == 7 {
			rights.BlackRightRookMoved = true
		}
	}

	// Update en passant
	if (piece == "P" || piece == "p") && Abs(toRow-fromRow) == 2 {
		*enPassantCol = fromCol
	} else {
		*enPassantCol = -1
	}

	return board, nil
}

// ReplayUCI replays the entire sequence of chess moves from the beginning using UCI notation.
// Returns status ("PLAYING", "WHITE_WON", "BLACK_WON", "DRAW").
func ReplayUCI(movesUCI string) (Board, bool, string, error) {
	board := NewInitialBoard()
	var rights CastlingRights
	enPassantCol := -1
	isWhiteTurn := true

	moves := splitWords(movesUCI)
	if len(moves) == 0 {
		return board, isWhiteTurn, "PLAYING", nil
	}

	for _, uci := range moves {
		fromRow, fromCol, toRow, toCol, promoPiece, err := ParseUCIMove(uci)
		if err != nil {
			return board, isWhiteTurn, "PLAYING", errors.New("langkah " + uci + " tidak valid: " + err.Error())
		}

		newBoard, err := ApplyMove(board, fromRow, fromCol, toRow, toCol, promoPiece, isWhiteTurn, &rights, &enPassantCol)
		if err != nil {
			return board, isWhiteTurn, "PLAYING", errors.New("langkah " + uci + " ilegal: " + err.Error())
		}
		board = newBoard

		// Flip turn
		isWhiteTurn = !isWhiteTurn

		// Check if the current player is checkmated or stalemated
		if !HasAnyLegalMoves(board, isWhiteTurn, rights, enPassantCol) {
			if IsKingInCheck(board, isWhiteTurn) {
				if isWhiteTurn {
					// White's turn with no legal moves and in check -> Black wins
					return board, isWhiteTurn, "BLACK_WON", nil
				}
				// Black's turn with no legal moves and in check -> White wins
				return board, isWhiteTurn, "WHITE_WON", nil
			}
			// Stalemate -> Draw
			return board, isWhiteTurn, "DRAW", nil
		}
	}

	return board, isWhiteTurn, "PLAYING", nil
}

