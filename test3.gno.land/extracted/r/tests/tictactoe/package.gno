package tictactoe

import (
  std
  "gno.land/p/demo/avl"
)

type gameState struct {
  ID  int64
	board      [3][3]int8
	turnPlayer int8
  player0 string
  player1 string
  winner int8
  status int8 // 0=open 1=closed
}

const (
	none   = iota
	cross  = iota
	circle = iota
)

var (
	// (not "games" because that's too useful a variable name)
	allGames     avl.Tree // string (game ID) -> *Game
	nextGameId int64 = 0
  availableGames []int64
	// Value must be sorted by game ID, descending
	userGames avl.Tree // std.Address -> []*Game
)
const zeroes = "000000000"

// zeroPad9 pads s to the left with zeroes until it's at least 9 bytes long.
func zeroPad9(s string) string {
	n := 9 - len(s)
	if n < 0 {
		return s
	}
	return zeroes[:n] + s
}
func StartGame() {

	std.AssertOriginCall()
	caller := std.GetOrigCaller()
  return startGame(caller)
}
func startGame(player std.Address) int64 {
	nextGameId++
	// id is zero-padded to work well with avl's alphabetic order.
	id := zeroPad9(strconv.FormatUint(nextGameId, 10))
	g := &gameState{
    ID: nextGameId, 
  	board:     [3][3]int8{},
  	turnPlayer: 1,
    player1: player,
    player2: "",
    status:0,
  }
	allGames.Set(g.ID, g)
  availableGames=append(availableGames, g.ID)
  addGameToUser(g.ID, player)
  return g.ID
}

func addGameToUser(gameId int64, player std.Address) {

	var games []int64
	v, ok := userGames.Get(string(player))
	if ok {
		games = v.([]int64)
	}
	// game must be at top, because it is the latest ID
	games = append([]int64{gameId}, games...)
	userGames.Set(string(addr), games)
}
func GetGames() []int64{

	std.AssertOriginCall()
	caller := std.GetOrigCaller()
  return getGames(caller)
}
func getGames(player std.Address) []int64{

	var games []int64
	v, ok := userGames.Get(string(player))
	if ok {
		games = v.([]int64)
	}
  return games
}
func GetAvailableGames() {
  return availableGames
}
func JoinGame(gameId int64) {

	std.AssertOriginCall()
	caller := std.GetOrigCaller()
  return joinGame(gameId, caller)
}
func joinGame(gameId int64, player std.Address) bool {
  graw, ok := allGames.get(gameId)
  if (ok) {
	  g := graw.(*gameState)
    if(g.player2!="") {
      panic("Game not available")
    }
    g.player2 = string(player)
    allGames.Set(g.ID, g)
    removeFromAvailableGames(g.ID)
    return ok
  }
  panic("Game not found")
}
func indexOf(element int64, data []int64) (int) {
   for k, v := range data {
       if element == v {
           return k
       }
   }
   return -1    //not found.
}
func removeFromAvailableGames(gameId int64) {
  index:=indexOf(gameId, availableGames)
  if (index==-1) {
    panic("Game was not available")
  }
  if (index==0 && len(availableGames)==1) {
    availableGames = []int64{}
  }else{
    newAvailableGames:=availableGames[:len(availableGames)-1]
    newAvailableGames[index]=availableGames[len(availableGames)-1]
    availableGames=append([]int64{},newAvailableGames...)
  }
}
func MakeMove(gameId int64, row, col int8) int8{

	std.AssertOriginCall()
	caller := std.GetOrigCaller()
  return makeMove(gameId, caller)
}
func makeMove(gameId int64, row, col int8, player std.Address) int8 {
  graw, ok := allGames.get(gameId)
  if (ok) {
	  g := graw.(*gameState)
    if (g.status==1) {
      panic("Game has ended")
    }
    if(g.player1!=string(player) && g.player2!=string(player)) {
      panic("You are not part of this game")
    }
    if(g.turnPlayer==1 && g.player1!=string(player)) || (g.turnPlayer==2 && g.player2!=string(player)) {
      panic("Not your turn")
    }
    if row < 0 || col < 0 || row >= 3 || col >= 3 {
      panic("Move position out of bounds")
    }
    if g.board[row][col] != 0 {
      panic("Square not empty")
    }

  	g.board[row][col] = g.turnPlayer
    winner:=checkForWinner(g)
    if (winner!=0) {
      if (winner!=3) {
        g.winner = winner
      }
      g.status = 1
    }else{
      if g.turnPlayer==1 {
        g.turnPlayer=2
      }else{
        g.turnPlayer=1
      }
    }
    allGames.Set(g.ID, g)
    return g.status
  }
  panic("Game not found")
}

func checkForWinner(g gameState) int8 {

	// define a lambda function for checking one line
	checkLine := func(startRow int, startColumn int, deltaRow int, deltaColumn int) gameResult {
		var lastSquare squareState = g.board[startRow][startColumn]
		row, column := startRow+deltaRow, startColumn+deltaColumn

		// loop starts from the second square(startRow + deltaRow, startColumn + deltaColumn)
		for row >= 0 && column >= 0 && row < 3 && column < 3 {

			// there can't be a winner if a empty square is present within the line
			if g.board[row][column] == none {
				return 0
			}

			if lastSquare != g.board[row][column] {
				return 0
			}

			lastSquare = g.board[row][column]
			row, column = row+deltaRow, column+deltaColumn
		}

		// someone has won the game
		if lastSquare == 1 {
			return 1
		} else if lastSquare == 2 {
			return 2
		}

		return 0
	}

	// check horizontal rows
	for row := 0; row < 3; row++ {
		if result := checkLine(row, 0, 0, 1); result != 0 {
			return result
		}
	}
	// check vertical columns
	for column := 0; column < 3; column++ {
		if result := checkLine(column, 0, 0, 1); result != 0 {
			return result
		}
	}
	// check top-left to bottom-right diagonal
	if result := checkLine(0, 0, 1, 1); result != 0 {
		return result
	}
	// check top-right to bottom-left diagonal
	if result := checkLine(0, 2, 1, -1); result != 0 {
		return result
	}
	// check for draw
	for _, row := range g.board {
		for _, square := range row {
			if square == none {
				return 0
			}
		}
	}
	// if no one wins yet, but none of the squares are empty
	return 3
}