package kewrchess

import (
	"errors"
	"time"

	"gno.land/p/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/chess"
)

// Timeout duration (seconds) for challenge proposals and turn timeouts
var ChallengeWindowSeconds int64 = 180 // 3-minute challenge window for settlement proposals
var TurnTimeoutSeconds int64 = 120     // 2-minute move timeout when opponent is AFK (Abandonment)

// getVerifiedCaller validates the format and availability of the caller address.
func getVerifiedCaller(caller address) (address, error) {
	if caller == "" {
		return "", errors.New("alamat caller tidak boleh kosong")
	}
	return caller, nil
}

// Stores all chess games permanently on the blockchain
var games []*Game
var nextGameID int

// On-chain matchmaking queue (FIFO)
var matchmakingQueue []address

// init automatically runs when contract is initialized
func init() {
	// Initial demo game setup: White player in Game #0
	pemberiTantangan := address("g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep")
	penerimaTantangan := address("g1kewrchessplayerblack777777777777777") // Simulated opponent

	newGame := NewGame(nextGameID, pemberiTantangan, penerimaTantangan)
	games = append(games, newGame)
	nextGameID++
}

// CreateGame creates a new direct game challenge
func CreateGame(caller address, opponent address) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if vCaller == opponent {
		return errors.New("tidak bisa bermain melawan diri sendiri")
	}

	newGame := NewGame(nextGameID, vCaller, opponent)
	games = append(games, newGame)
	nextGameID++

	return nil
}

// JoinQueue registers a player into the on-chain matchmaking queue.
// If the queue is empty, the player is added to the queue.
// If another player is already waiting, both players are immediately matched into a new game.
func JoinQueue(caller address) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	// Check if player is already in queue
	for _, addr := range matchmakingQueue {
		if addr == vCaller {
			return errors.New("anda sudah berada di dalam antrean matchmaking")
		}
	}

	// If queue is empty, add caller to queue
	if len(matchmakingQueue) == 0 {
		matchmakingQueue = append(matchmakingQueue, vCaller)
		return nil
	}

	// If a player is waiting, take the first player (FIFO)
	opponent := matchmakingQueue[0]
	matchmakingQueue = matchmakingQueue[1:]

	// Create new game: waiting player becomes White, caller becomes Black
	newGame := NewGame(nextGameID, opponent, vCaller)
	games = append(games, newGame)
	nextGameID++

	return nil
}

// LeaveQueue cancels and removes a player from the on-chain matchmaking queue
func LeaveQueue(caller address) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	for i, addr := range matchmakingQueue {
		if addr == vCaller {
			matchmakingQueue = append(matchmakingQueue[:i], matchmakingQueue[i+1:]...)
			return nil
		}
	}
	return errors.New("anda tidak sedang berada di dalam antrean matchmaking")
}

func makeMoveInternal(caller address, gameID int, fromRow, fromCol, toRow, toCol int, promoPiece string) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if g.isWhiteTurn && vCaller != g.white {
		return errors.New("bukan giliran Anda (Putih)")
	}
	if !g.isWhiteTurn && vCaller != g.black {
		return errors.New("bukan giliran Anda (Hitam)")
	}

	if fromRow < 0 || fromRow > 7 || fromCol < 0 || fromCol > 7 ||
		toRow < 0 || toRow > 7 || toCol < 0 || toCol > 7 {
		return errors.New("koordinat di luar papan")
	}

	piece := g.board[fromRow][fromCol]
	if piece == "." {
		return errors.New("tidak ada bidak di posisi asal")
	}

	// Delegate move validation to package p/demo/chess
	if !chess.IsValidMove(g.board, fromRow, fromCol, toRow, toCol, g.isWhiteTurn, g.castling, g.enPassantCol) {
		return errors.New("langkah catur tidak valid")
	}

	isWhite := chess.IsWhitePiece(piece)

	// Validate pawn promotion
	isPromotion := (piece == "P" && toRow == 0) || (piece == "p" && toRow == 7)
	var finalPiece string = piece
	if isPromotion {
		promoted, err := chess.NormalizePromotionPiece(promoPiece, isWhite)
		if err != nil {
			return err
		}
		finalPiece = promoted
	}

	isCastling := (piece == "K" || piece == "k") && chess.Abs(toCol-fromCol) == 2
	isEnPassant := (piece == "P" || piece == "p") && toCol == g.enPassantCol && fromCol != toCol && g.board[toRow][toCol] == "."

	// Verify move does not leave own king in check
	origDest := g.board[toRow][toCol]
	g.board[toRow][toCol] = piece
	g.board[fromRow][fromCol] = "."

	var epRow int
	var epPiece string
	if isEnPassant {
		if isWhite {
			epRow = 3
		} else {
			epRow = 4
		}
		epPiece = g.board[epRow][toCol]
		g.board[epRow][toCol] = "."
	}

	inCheck := chess.IsKingInCheck(g.board, isWhite)

	// Revert simulation
	g.board[fromRow][fromCol] = piece
	g.board[toRow][toCol] = origDest
	if isEnPassant {
		g.board[epRow][toCol] = epPiece
	}

	if inCheck {
		return errors.New("langkah ilegal: tidak boleh membiarkan Raja Anda terkena skak")
	}

	// Execute move
	g.board[toRow][toCol] = finalPiece
	g.board[fromRow][fromCol] = "."

	// Execute En Passant capture
	if isEnPassant {
		if isWhite {
			g.board[3][toCol] = "."
		} else {
			g.board[4][toCol] = "."
		}
	}

	// Move Rook during castling
	if isCastling {
		if isWhite {
			if toCol == 6 { // Kingside
				g.board[7][5] = "R"
				g.board[7][7] = "."
			} else if toCol == 2 { // Queenside
				g.board[7][3] = "R"
				g.board[7][0] = "."
			}
		} else {
			if toCol == 6 { // Kingside
				g.board[0][5] = "r"
				g.board[0][7] = "."
			} else if toCol == 2 { // Queenside
				g.board[0][3] = "r"
				g.board[0][0] = "."
			}
		}
	}

	// Update castling rights
	if piece == "K" {
		g.castling.WhiteKingMoved = true
	} else if piece == "k" {
		g.castling.BlackKingMoved = true
	} else if piece == "R" {
		if fromRow == 7 && fromCol == 0 {
			g.castling.WhiteLeftRookMoved = true
		} else if fromRow == 7 && fromCol == 7 {
			g.castling.WhiteRightRookMoved = true
		}
	} else if piece == "r" {
		if fromRow == 0 && fromCol == 0 {
			g.castling.BlackLeftRookMoved = true
		} else if fromRow == 0 && fromCol == 7 {
			g.castling.BlackRightRookMoved = true
		}
	}

	// Update en passant vulnerability
	if (piece == "P" || piece == "p") && chess.Abs(toRow-fromRow) == 2 {
		g.enPassantCol = fromCol
	} else {
		g.enPassantCol = -1
	}

	// Detect Checkmate or Stalemate for opponent
	opponentIsWhite := !isWhite
	if !chess.HasAnyLegalMoves(g.board, opponentIsWhite, g.castling, g.enPassantCol) {
		if chess.IsKingInCheck(g.board, opponentIsWhite) {
			if isWhite {
				g.status = "WHITE_WON"
			} else {
				g.status = "BLACK_WON"
			}
		} else {
			g.status = "DRAW"
		}
	}

	g.isWhiteTurn = !g.isWhiteTurn
	g.drawOfferedBy = ""
	g.turnDeadline = 0
	g.turnChallengedBy = ""

	return nil
}

// MakeMove moves a piece (defaults to Queen on promotion)
func MakeMove(caller address, gameID int, fromRow, fromCol, toRow, toCol int) error {
	return makeMoveInternal(caller, gameID, fromRow, fromCol, toRow, toCol, "Q")
}

// MakeMovePromote moves a piece with a specified promotion piece (Q, R, B, N)
func MakeMovePromote(caller address, gameID int, fromRow, fromCol, toRow, toCol int, promoPiece string) error {
	return makeMoveInternal(caller, gameID, fromRow, fromCol, toRow, toCol, promoPiece)
}

// Resign resigns the game for the calling player
func Resign(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" && g.status != "PROPOSED" {
		return errors.New("game sudah selesai")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menyerah")
	}

	g.resignedBy = vCaller
	if vCaller == g.white {
		g.status = "BLACK_WON"
	} else {
		g.status = "WHITE_WON"
	}

	g.settledBy = vCaller
	g.drawOfferedBy = ""
	g.turnDeadline = 0
	g.turnChallengedBy = ""
	g.challengeDeadline = 0
	return nil
}

// OfferDraw offers a draw to the opponent
func OfferDraw(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menawarkan remis")
	}

	if g.drawOfferedBy == vCaller {
		return errors.New("anda sudah mengajukan tawaran remis")
	}

	if g.drawOfferedBy != "" && g.drawOfferedBy != vCaller {
		g.status = "DRAW"
		g.drawOfferedBy = ""
		return nil
	}

	g.drawOfferedBy = vCaller
	return nil
}

// AcceptDraw accepts a draw offer from the opponent
func AcceptDraw(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menerima remis")
	}

	if g.drawOfferedBy == "" {
		return errors.New("tidak ada tawaran remis yang sedang aktif")
	}

	if g.drawOfferedBy == vCaller {
		return errors.New("tidak bisa menerima tawaran remis yang Anda ajukan sendiri")
	}

	g.status = "DRAW"
	g.drawOfferedBy = ""
	return nil
}

// DeclineDraw declines a draw offer from the opponent
func DeclineDraw(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menolak remis")
	}

	if g.drawOfferedBy == "" {
		return errors.New("tidak ada tawaran remis yang sedang aktif")
	}

	if g.drawOfferedBy == vCaller {
		return errors.New("tidak bisa menolak tawaran remis yang Anda ajukan sendiri")
	}

	g.drawOfferedBy = ""
	return nil
}

// ProposeSettlement submits a victory claim for off-chain chess results.
// Prevents fraudulent opponent moves: proposal opens a challenge period.
// Opponent can confirm immediately (ConfirmSettlement), or dispute if cheated (DisputeSettlement).
// If opponent does not respond, winner can finalize after ChallengeWindowSeconds expires.
func ProposeSettlement(caller address, gameID int, movesUCI string) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat mengajukan settlement")
	}

	if g.settledBy != "" {
		return errors.New("game ini sudah diselesaikan di blockchain")
	}

	if g.status != "PLAYING" {
		return errors.New("game ini sedang dalam status " + g.status)
	}

	// Replay chess moves from the beginning using package gno.land/p/demo/chess
	finalBoard, _, status, err := chess.ReplayUCI(movesUCI)
	if err != nil {
		return errors.New("verifikasi langkah catur gagal: " + err.Error())
	}

	if status == "PLAYING" {
		return errors.New("rangkaian langkah catur belum menghasilkan skakmat atau remis")
	}

	// Verify winner claim rights
	if status == "WHITE_WON" && vCaller != g.white {
		return errors.New("hanya pemain Putih yang berhak klaim kemenangan untuk White")
	}
	if status == "BLACK_WON" && vCaller != g.black {
		return errors.New("hanya pemain Hitam yang berhak klaim kemenangan untuk Black")
	}

	g.board = finalBoard
	g.proposedBy = vCaller
	g.pendingStatus = status
	g.challengeDeadline = time.Now().Unix() + ChallengeWindowSeconds
	g.status = "PROPOSED"
	g.drawOfferedBy = ""
	g.turnDeadline = 0
	g.turnChallengedBy = ""

	return nil
}

// ConfirmSettlement allows opponent to immediately approve final result without waiting for challenge window
func ConfirmSettlement(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PROPOSED" {
		return errors.New("tidak ada proposal settlement yang sedang aktif")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat mengonfirmasi")
	}

	if vCaller == g.proposedBy {
		return errors.New("tidak bisa mengonfirmasi proposal yang Anda ajukan sendiri")
	}

	g.status = g.pendingStatus
	g.settledBy = g.proposedBy
	g.challengeDeadline = 0
	return nil
}

// FinalizeSettlement officially finalizes the game after the challenge period has passed
func FinalizeSettlement(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PROPOSED" {
		return errors.New("tidak ada proposal settlement yang sedang aktif")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat memfinalisasi")
	}

	now := time.Now().Unix()
	if now < g.challengeDeadline {
		return errors.New("jendela sanggahan (challenge period) belum berakhir")
	}

	g.status = g.pendingStatus
	g.settledBy = g.proposedBy
	g.challengeDeadline = 0
	return nil
}

// DisputeSettlement allows opponent to dispute a fraudulent settlement proposal
func DisputeSettlement(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PROPOSED" {
		return errors.New("tidak ada proposal settlement yang sedang aktif")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menyanggah")
	}

	if vCaller == g.proposedBy {
		return errors.New("tidak bisa menyanggah proposal yang Anda ajukan sendiri")
	}

	// Cancel fraudulent proposal and revert game status back to PLAYING
	g.status = "PLAYING"
	g.proposedBy = ""
	g.pendingStatus = ""
	g.challengeDeadline = 0
	return nil
}

// SettleGame proposes settlement and finalizes immediately if challenge window is 0
func SettleGame(caller address, gameID int, movesUCI string) error {
	err := ProposeSettlement(caller, gameID, movesUCI)
	if err != nil {
		return err
	}
	if ChallengeWindowSeconds <= 0 {
		return FinalizeSettlement(caller, gameID)
	}
	return nil
}

// StartTurnTimer is initiated when opponent goes AFK or closes browser (Rage Quit) during an off-chain game.
// Player submits current move history (currentMovesUCI).
// Smart contract validates the board and ensures it is the OPPONENT'S TURN.
func StartTurnTimer(caller address, gameID int, currentMovesUCI string) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if vCaller != g.white && vCaller != g.black {
		return errors.New("hanya pemain dalam game ini yang dapat menuntut timer giliran")
	}

	currentBoard, nextIsWhiteTurn, status, err := chess.ReplayUCI(currentMovesUCI)
	if err != nil {
		return errors.New("verifikasi langkah posisi saat ini gagal: " + err.Error())
	}

	if status != "PLAYING" {
		return errors.New("posisi catur ini sudah selesai (skakmat/remis), gunakan SettleGame")
	}

	// Validate that next turn is the opponent's turn, not the caller's
	if vCaller == g.white && nextIsWhiteTurn {
		return errors.New("saat ini adalah giliran Anda sendiri (Putih), lakukan langkah Anda terlebih dahulu")
	}
	if vCaller == g.black && !nextIsWhiteTurn {
		return errors.New("saat ini adalah giliran Anda sendiri (Hitam), lakukan langkah Anda terlebih dahulu")
	}

	g.board = currentBoard
	g.isWhiteTurn = nextIsWhiteTurn
	g.turnChallengedBy = vCaller
	g.turnDeadline = time.Now().Unix() + TurnTimeoutSeconds

	return nil
}

// ClaimTimeout allows the challenger to win the game after the opponent goes AFK/rage quits
// and turnDeadline has passed without a response move from the opponent.
func ClaimTimeout(caller address, gameID int) error {
	vCaller, err := getVerifiedCaller(caller)
	if err != nil {
		return err
	}

	if gameID < 0 || gameID >= len(games) {
		return errors.New("game tidak ditemukan")
	}

	g := games[gameID]

	if g.status != "PLAYING" {
		return errors.New("game sudah selesai")
	}

	if g.turnDeadline == 0 {
		return errors.New("tidak ada batas waktu giliran yang sedang berjalan")
	}

	now := time.Now().Unix()
	if now < g.turnDeadline {
		return errors.New("batas waktu giliran lawan belum habis")
	}

	if vCaller != g.turnChallengedBy {
		return errors.New("hanya pemain yang menuntut timer yang dapat mengklaim kemenangan timeout")
	}

	if vCaller == g.white {
		g.status = "WHITE_WON"
	} else {
		g.status = "BLACK_WON"
	}

	g.settledBy = vCaller
	g.turnDeadline = 0
	g.turnChallengedBy = ""

	return nil
}

// GetGamesCount returns the total number of games
func GetGamesCount() int {
	return len(games)
}

// GetBoard returns the 8x8 board for a given game ID
func GetBoard(gameID int) [8][8]string {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return [8][8]string(games[gameID].board)
}

// GetWhitePlayer returns the White player address for a given game ID
func GetWhitePlayer(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].white
}

// GetBlackPlayer returns the Black player address for a given game ID
func GetBlackPlayer(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].black
}

// IsWhiteTurn returns whether it is White's turn for a given game ID
func IsWhiteTurn(gameID int) bool {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].isWhiteTurn
}

// GetGameStatus returns the game status for a given game ID
func GetGameStatus(gameID int) string {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].status
}

// GetDrawOfferedBy returns the address that offered a draw, or empty address if none
func GetDrawOfferedBy(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].drawOfferedBy
}

// GetResignedBy returns the address of the player who resigned, or empty address if none
func GetResignedBy(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].resignedBy
}

// GetQueueCount returns the number of players waiting in the matchmaking queue
func GetQueueCount() int {
	return len(matchmakingQueue)
}

// IsInQueue checks if an address is currently waiting in the matchmaking queue
func IsInQueue(addr address) bool {
	for _, a := range matchmakingQueue {
		if a == addr {
			return true
		}
	}
	return false
}

// GetActiveGameForPlayer searches for the latest active game ("PLAYING") for a given address.
// Returns -1 if no active game found.
func GetActiveGameForPlayer(addr address) int {
	for i := len(games) - 1; i >= 0; i-- {
		g := games[i]
		if (g.white == addr || g.black == addr) && g.status == "PLAYING" {
			return g.id
		}
	}
	return -1
}

// GetLatestGameForPlayer returns the latest game ID involving the player, or -1 if none.
func GetLatestGameForPlayer(addr address) int {
	for i := len(games) - 1; i >= 0; i-- {
		g := games[i]
		if g.white == addr || g.black == addr {
			return g.id
		}
	}
	return -1
}

// GetSettledBy returns the address that finalized the game settlement on-chain
func GetSettledBy(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].settledBy
}

// GetProposedBy returns the address that proposed settlement
func GetProposedBy(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].proposedBy
}

// GetPendingStatus returns the pending status of settlement
func GetPendingStatus(gameID int) string {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].pendingStatus
}

// GetChallengeDeadline returns the deadline unix timestamp for challenging settlement
func GetChallengeDeadline(gameID int) int64 {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].challengeDeadline
}

// GetTurnDeadline returns the deadline unix timestamp for turn timeout
func GetTurnDeadline(gameID int) int64 {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].turnDeadline
}

// GetTurnChallengedBy returns the address that initiated the turn timer
func GetTurnChallengedBy(gameID int) address {
	if gameID < 0 || gameID >= len(games) {
		panic("game tidak ditemukan")
	}
	return games[gameID].turnChallengedBy
}

