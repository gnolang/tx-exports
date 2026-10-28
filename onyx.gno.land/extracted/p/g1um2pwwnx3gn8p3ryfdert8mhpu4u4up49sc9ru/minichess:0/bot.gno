package minichess

// The bot is an iterative-deepening negamax search with alpha-beta pruning,
// a check extension and a capped quiescence search. Every level has a hard
// node budget, so the gas a bot reply costs is bounded no matter how
// complicated the position is. It is fully deterministic: the same
// position, level and seed always produce the same move.

const (
	MinLevel = 1
	MaxLevel = 3

	mateScore = 100000
	infScore  = 1000000
	maxPly    = 12
)

// LevelInfo describes the search limits of a bot level.
type LevelInfo struct {
	Name     string
	MaxDepth int // full-width plies searched before quiescence
	QDepth   int // capture plies searched after MaxDepth
	Budget   int // maximum nodes visited per move (bounds the gas cost)
}

var levels = [MaxLevel + 1]LevelInfo{
	{},
	{Name: "easy", MaxDepth: 1, QDepth: 2, Budget: 200},
	{Name: "medium", MaxDepth: 2, QDepth: 3, Budget: 900},
	{Name: "hard", MaxDepth: 3, QDepth: 3, Budget: 1500},
}

// Level returns the limits for a level, clamped to [MinLevel, MaxLevel].
func Level(level int) LevelInfo {
	if level < MinLevel {
		level = MinLevel
	}
	if level > MaxLevel {
		level = MaxLevel
	}
	return levels[level]
}

// Evaluate scores the position in centipawns from the side to move's view.
func (p Position) Evaluate() int {
	return newEngine(&p).eval()
}

func (e *engine) eval() int {
	if e.turn == Black {
		return -e.score
	}
	return e.score
}

// BestMove returns the bot's choice for the side to move. seed breaks ties
// between equally scored moves so games don't all look identical; pass
// something like gameID*1000+ply. ok is false if there are no legal moves.
func BestMove(p Position, level int, seed int) (Move, bool) {
	best, _, ok := searchWith(p, Level(level), seed, nil)
	return best, ok
}

// BestMoveWithHistory is BestMove for a game in progress: history holds
// the Hash of earlier positions (since the last capture or pawn move).
// Moves that repeat one of them are scored as a draw, so the bot avoids
// repetition when it is ahead and steers toward it when it is behind.
func BestMoveWithHistory(p Position, level int, seed int, history []uint64) (Move, bool) {
	best, _, ok := searchWith(p, Level(level), seed, history)
	return best, ok
}

// Hash returns a 64-bit hash of the position (for repetition tracking).
func (p Position) Hash() uint64 {
	return newEngine(&p).hash()
}

// search is BestMove plus the number of nodes visited (for tests).
func search(p Position, level int, seed int) (Move, int, bool) {
	return searchWith(p, Level(level), seed, nil)
}

func searchWith(p Position, info LevelInfo, seed int, history []uint64) (Move, int, bool) {
	e := newEngine(&p)
	order := e.legal()
	if len(order) == 0 {
		return Move{}, 0, false
	}
	if len(order) == 1 {
		return decode(order[0]), 0, true
	}
	e.budget = info.Budget
	e.qdepth = info.QDepth
	if seed < 0 {
		seed = -seed
	}

	var chosen []int
	for depth := 1; depth <= info.MaxDepth; depth++ {
		bestScore := -infScore
		var ties []int
		for _, m := range order {
			// Window (bestScore-1, inf): equal-best moves get exact scores,
			// worse moves fail low at <= bestScore-1.
			alpha := -infScore
			if bestScore > -infScore {
				alpha = bestScore - 1
			}
			u := e.make(m)
			score := 0 // a repeated position counts as a draw
			if len(history) == 0 || !containsU64(history, e.hash()) {
				score = -e.negamax(depth-1, -infScore, -alpha, 1, e.givesCheck(m, u))
			}
			e.unmake(m, u)
			if e.aborted {
				break
			}
			if score > bestScore {
				bestScore = score
				ties = []int{m}
			} else if score == bestScore {
				ties = append(ties, m)
			}
		}
		if e.aborted {
			// Moves are searched best-first, so any move that finished at
			// this depth is at least as reliable as the previous result.
			if len(ties) > 0 {
				chosen = ties
			}
			break
		}
		chosen = ties
		if bestScore >= mateScore-maxPly || depth == info.MaxDepth {
			break // forced mate found, or done
		}
		// Search the current best moves first in the next iteration.
		next := make([]int, 0, len(order))
		next = append(next, ties...)
		for _, m := range order {
			if !containsInt(ties, m) {
				next = append(next, m)
			}
		}
		order = next
	}
	if len(chosen) == 0 {
		chosen = order[:1] // budget ran out before depth 1 finished
	}
	return decode(chosen[seed%len(chosen)]), e.nodes, true
}

func containsU64(list []uint64, x uint64) bool {
	for _, y := range list {
		if y == x {
			return true
		}
	}
	return false
}

func containsInt(list []int, x int) bool {
	for _, y := range list {
		if y == x {
			return true
		}
	}
	return false
}

// captureKey ranks a capture: most valuable victim first, then least
// valuable attacker (MVV-LVA). Promotions count as winning a queen.
func (e *engine) captureKey(m int) int {
	v := pieceValue[e.b[(m>>6)&63].Type()]*16 - int(e.b[m&63].Type())
	if m >= 4096 {
		v += pieceValue[Queen] * 16
	}
	return v
}

// orderCaptures sorts captures by captureKey, best first.
func (e *engine) orderCaptures(caps []int, n int) {
	for i := 1; i < n; i++ {
		m := caps[i]
		v := e.captureKey(m)
		j := i - 1
		for j >= 0 && e.captureKey(caps[j]) < v {
			caps[j+1] = caps[j]
			j--
		}
		caps[j+1] = m
	}
}

// killersFirst moves this ply's killer moves to the front of the quiets.
func (e *engine) killersFirst(pb *plyBuf, ply int) {
	if ply > maxPly {
		return
	}
	front := 0
	for k := 0; k < 2; k++ {
		km := e.killers[ply][k]
		if km == 0 {
			continue
		}
		for j := front; j < pb.nq; j++ {
			if pb.quiets[j] == km {
				pb.quiets[j], pb.quiets[front] = pb.quiets[front], km
				front++
				break
			}
		}
	}
}

func (e *engine) addKiller(ply, m int) {
	if e.killers[ply][0] != m {
		e.killers[ply][1] = e.killers[ply][0]
		e.killers[ply][0] = m
	}
}

// negamax assumes the position is legal; inCheck says whether the side to
// move is in check (computed cheaply by the parent via givesCheck).
func (e *engine) negamax(depth, alpha, beta, ply int, inCheck bool) int {
	e.nodes++
	if e.nodes > e.budget {
		e.aborted = true
		return 0
	}
	if e.half >= 100 {
		return 0
	}
	if depth <= 0 {
		if !inCheck || ply >= maxPly {
			return e.quiesce(alpha, beta, ply, 0, inCheck)
		}
		depth = 1 // check extension: never stop the search in check
	}
	pb := e.buf(ply)
	e.gen(pb, false)
	if pb.nc > 1 {
		e.orderCaptures(pb.caps, pb.nc)
	}
	e.killersFirst(pb, ply)

	best := -infScore
	nc, n := pb.nc, pb.nc+pb.nq
	for i := 0; i < n; i++ {
		m := 0
		if i < nc {
			m = pb.caps[i]
		} else {
			m = pb.quiets[i-nc]
		}
		u := e.make(m)
		if !e.moveIsLegal(m, u, inCheck) {
			e.unmake(m, u)
			continue
		}
		score := -e.negamax(depth-1, -beta, -alpha, ply+1, e.givesCheck(m, u))
		e.unmake(m, u)
		if e.aborted {
			return 0
		}
		if score > best {
			best = score
			if score > alpha {
				alpha = score
				if alpha >= beta {
					if i >= nc && ply <= maxPly {
						e.addKiller(ply, m)
					}
					return best
				}
			}
		}
	}
	if best == -infScore { // no legal moves
		if inCheck {
			return -mateScore + ply
		}
		return 0 // stalemate
	}
	return best
}

func (e *engine) quiesce(alpha, beta, ply, qdepth int, inCheck bool) int {
	e.nodes++
	if e.nodes > e.budget {
		e.aborted = true
		return 0
	}
	if inCheck && ply < maxPly {
		// Standing pat is not an option in check: search all evasions.
		return e.negamax(1, alpha, beta, ply, true)
	}
	stand := e.eval()
	if stand >= beta || qdepth >= e.qdepth {
		return stand
	}
	if stand+1000 <= alpha {
		return alpha // delta pruning: even winning a queen can't help
	}
	if stand > alpha {
		alpha = stand
	}
	pb := e.buf(ply)
	e.gen(pb, true)
	if pb.nc > 1 {
		e.orderCaptures(pb.caps, pb.nc)
	}
	them := 1 - e.turn
	for i := 0; i < pb.nc; i++ {
		m := pb.caps[i]
		// Skip losing captures: a more valuable piece taking a defended,
		// less valuable one (e.g. queen takes a guarded pawn).
		to := (m >> 6) & 63
		if m < 4096 && pieceValue[e.b[m&63].Type()] > pieceValue[e.b[to].Type()] && e.attacked(to, them) {
			continue
		}
		u := e.make(m)
		if !e.moveIsLegal(m, u, inCheck) {
			e.unmake(m, u)
			continue
		}
		score := -e.quiesce(-beta, -alpha, ply+1, qdepth+1, e.givesCheck(m, u))
		e.unmake(m, u)
		if e.aborted {
			return 0
		}
		if score >= beta {
			return score
		}
		if score > alpha {
			alpha = score
		}
	}
	return alpha
}
