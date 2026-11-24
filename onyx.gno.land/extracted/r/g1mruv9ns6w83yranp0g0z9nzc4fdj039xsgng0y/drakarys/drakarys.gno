// Drakarys_GAME_0 - gno.land port of sc/src/Drakarys_GAME_0.sol.
//
// Same commit/reveal protocol and game transition logic as the EVM, Solana
// and NEAR deployments. Commitments are identical too: keccak256 of
// abi.encodePacked(move) - so the same moveCommitment() the relay uses for
// every other chain verifies here unchanged.
//
// Agent identities are opaque strings (the relay uses the agents' EVM hex
// addresses, keeping identity consistent across chains). Like the Solana
// deployment, the first commit binds the identities for the rest of the
// match and only the operator account may relay commits/reveals.
//
// Indexing-friendly extras vs EVM/Solana (same design as the NEAR port):
//   - full state history stored on-chain (bounded by N_ROUNDS states)
//   - per-match event log (commits, reveals, interceptions, shots, start/end)
//   - qeval_json views return JSON strings - one view call yields complete,
//     always-consistent match data.

package drakarys

import (
	"chain/runtime/unsafe"
	"crypto/keccak256"
	"strconv"
	"strings"
)

const (
	nRounds        = 20
	nTeams         = 2
	nPlayers       = 11
	nStats         = 2
	deltaXRange    = 5
	deltaYRange    = 5
	fieldWidth     = 1024
	fieldHeight    = 512
	goalkeeperX    = fieldWidth / 20
	nBallSteps     = 3
	interceptionD2 = 100
)

type TeamState struct {
	PlayerPositions [11][2]int64 `json:"player_positions"`
	Pass            bool         `json:"pass"`
	PassingTo       uint64       `json:"passing_to"`
	Shoot           bool         `json:"shoot"`
}

type GameState struct {
	Teams            [2]TeamState `json:"teams"`
	Score            [2]uint64    `json:"score"`
	HasBallTeamIdx   uint8        `json:"has_ball_team_idx"`
	HasBallPlayerIdx uint8        `json:"has_ball_player_idx"`
}

// One agent's move for a round - mirror `Move` in the EVM contract.
// SeedPart is the agent's 128-bit seed contribution as a 32-byte word
// (u256 in the other contracts); we keep the raw bytes so the commitment
// covers the full word exactly like abi.encodePacked does.
type Move struct {
	StateIdx             uint64      `json:"state_idx"`
	DeltaPlayerPositions [11][2]int64 `json:"delta_player_positions"`
	Commands             [2]uint64   `json:"commands"`
	SeedPart             [32]byte    `json:"seed_part"`
}

// A game event. Kind is one of: match_started, move_committed,
// move_revealed, interception, shot, match_ended. Data/Moves carry the
// payload for committed/revealed events (HasData/HasMoves flags - gno has
// no nil-safe optional encoding, and we hand-roll the JSON anyway).
type MatchEvent struct {
	Kind      string
	StateIdx  uint64
	TeamIdx   uint64
	PlayerIdx uint64
	X         int64
	Y         int64
	Goal      bool
	Data      [2][32]byte
	Moves     []Move
	HasData   bool
	HasMoves  bool
}

type MatchEntry struct {
	MatchIdx    uint64
	StateIdx    uint8
	Agents      [2]string // identity strings bound on first commit
	PlayerStats [2][11][2]int64
	Commit      [2][32]byte
	HasCommit   bool
	State       GameState
	States      []GameState // full history for indexers
	Events      []MatchEvent
}

var (
	matches  = map[string]*MatchEntry{}
	matchIDs []uint64
	operator string // g1... account allowed to relay commits/reveals
)

func init() {
	// addpkg-time caller - mirrors the EVM constructor's `operator = msg.sender`
	operator = unsafe.OriginCaller().String()
}

// The operator relays every commit/reveal - same trust model as the other
// chains. Require a direct user call (no maketx run / cross-realm proxy).
func requireOperator(cur realm) {
	prev := cur.Previous()
	if !prev.IsUserCall() || prev.Address().String() != operator {
		panic("Not operator")
	}
}

// Commit relays both agents' commitments for the current round.
// c0/c1 are 64-char hex keccak256 commitments; a0/a1 are the agent
// identity strings bound on first commit (EVM addresses upstream).
func Commit(cur realm, matchIdx uint64, c0 string, c1 string, a0 string, a1 string) {
	requireOperator(cur)

	key := strconv.FormatUint(matchIdx, 10)
	m, ok := matches[key]
	if !ok {
		m = &MatchEntry{MatchIdx: matchIdx}
		matches[key] = m
		matchIDs = append(matchIDs, matchIdx)
	}

	agents := [2]string{a0, a1}
	for i := 0; i < nTeams; i++ {
		if m.Agents[i] == "" {
			m.Agents[i] = agents[i]
		} else if m.Agents[i] != agents[i] {
			panic("Invalid agent")
		}
	}
	m.Commit = [2][32]byte{hexDecode32(c0), hexDecode32(c1)}
	m.HasCommit = true

	e := MatchEvent{Kind: "move_committed", StateIdx: uint64(m.StateIdx)}
	e.Data = m.Commit
	e.HasData = true
	m.Events = append(m.Events, e)
}

// Reveal applies both agents' revealed moves - the round's state transition.
// Each move is a comma-separated list of 26 integers:
//
//	stateIdx, dx0,dy0, dx1,dy1, ..., dx10,dy10, cmd0,cmd1, seedPart
func Reveal(cur realm, matchIdx uint64, move0 string, move1 string) {
	requireOperator(cur)

	key := strconv.FormatUint(matchIdx, 10)
	m := matches[key]
	if m == nil {
		panic("Unknown match")
	}

	// Match is over
	if m.StateIdx == nRounds {
		return
	}

	moves := [2]Move{parseMove(move0), parseMove(move1)}

	var seed int64

	// Round 0 reveals the seed parts and builds the kick-off state
	if m.StateIdx == 0 {
		if !m.HasCommit {
			panic("Invalid commit")
		}
		for i := 0; i < len(moves); i++ {
			var encoded []byte
			packU256(matchIdx, &encoded)
			encoded = append(encoded, moves[i].SeedPart[:]...)
			if keccak256.Sum256(encoded) != m.Commit[i] {
				panic("Invalid commit")
			}
		}

		seed = rng(seedI64Half(moves[0].SeedPart) + seedI64(moves[1].SeedPart))

		var st GameState
		for t := 0; t < nTeams; t++ {
			for i := 0; i < nPlayers; i++ {
				for s := 0; s < nStats; s++ {
					seed = rng(seed)
					stat := 10 + seed%90
					if stat < 0 {
						stat = -stat
					}
					m.PlayerStats[t][i][s] = stat
				}
				// note: implicitly the goalkeeper of team 0 has the ball
				if i == 0 {
					// goalkeeper holds a fixed position on his goal line
					if t == 0 {
						st.Teams[t].PlayerPositions[i][0] = goalkeeperX
					} else {
						st.Teams[t].PlayerPositions[i][0] = fieldWidth - goalkeeperX
					}
					st.Teams[t].PlayerPositions[i][1] = fieldHeight / 2
				} else {
					// 4-3-3 formation spread evenly down the field, mirrored for team 1
					var x, y int64
					if i <= 4 {
						x = fieldWidth / 5
						y = fieldHeight * int64(i) / 5
					} else if i <= 7 {
						x = fieldWidth * 2 / 5
						y = fieldHeight * int64(2*(i-5)+3) / 10
					} else {
						x = fieldWidth * 3 / 5
						y = fieldHeight * int64(i-7) / 4
					}
					if t == 0 {
						st.Teams[t].PlayerPositions[i][0] = x
					} else {
						st.Teams[t].PlayerPositions[i][0] = fieldWidth - x
					}
					st.Teams[t].PlayerPositions[i][1] = y
				}
			}
		}

		m.State = st
		m.States = append(m.States, st)
		m.StateIdx++

		m.Events = append(m.Events, MatchEvent{Kind: "match_started"})
		e := MatchEvent{Kind: "move_revealed", StateIdx: 0, Moves: moves[:], HasMoves: true}
		m.Events = append(m.Events, e)
		return
	}

	curr := m.State
	var next GameState

	stateIdx := m.StateIdx
	if !m.HasCommit {
		panic("Invalid commit")
	}
	for i := 0; i < len(moves); i++ {
		var encoded []byte
		packU256(matchIdx, &encoded)
		packU256(moves[i].StateIdx, &encoded)
		for j := 0; j < nPlayers; j++ {
			packI256(moves[i].DeltaPlayerPositions[j][0], &encoded)
			packI256(moves[i].DeltaPlayerPositions[j][1], &encoded)
		}
		for c := 0; c < 2; c++ {
			packU256(moves[i].Commands[c], &encoded)
		}
		encoded = append(encoded, moves[i].SeedPart[:]...)
		if keccak256.Sum256(encoded) != m.Commit[i] {
			panic("Invalid commit")
		}
	}

	// seed the rng for this round from both agents' seed parts
	seed = rng(seedI64Half(moves[0].SeedPart) + seedI64(moves[1].SeedPart))

	m.Events = append(m.Events, MatchEvent{
		Kind: "move_revealed", StateIdx: uint64(stateIdx), Moves: moves[:], HasMoves: true,
	})

	// Phase 1: Move the players
	for i := 0; i < len(moves); i++ {
		for j := 0; j < nPlayers; j++ {
			// goalkeeper never leaves his position on the goal line
			if j == 0 {
				next.Teams[i].PlayerPositions[j] = curr.Teams[i].PlayerPositions[j]
				continue
			}
			// cap the delta player positions
			dx := clamp(moves[i].DeltaPlayerPositions[j][0], -deltaXRange, deltaXRange)
			dy := clamp(moves[i].DeltaPlayerPositions[j][1], -deltaYRange, deltaYRange)

			// cap the new position based on field size
			next.Teams[i].PlayerPositions[j][0] = clamp(
				curr.Teams[i].PlayerPositions[j][0]+dx*m.PlayerStats[i][j][1],
				0, fieldWidth)
			next.Teams[i].PlayerPositions[j][1] = clamp(
				curr.Teams[i].PlayerPositions[j][1]+dy*m.PlayerStats[i][j][1],
				0, fieldHeight)
		}
	}

	// Phase 2: Handle `pass` = command[0] - encoded as 100...00 | playerIdx
	next.HasBallTeamIdx = curr.HasBallTeamIdx
	next.HasBallPlayerIdx = curr.HasBallPlayerIdx
	next.Score = curr.Score
	hasBallTeamIdx := int(curr.HasBallTeamIdx)
	hasBallPlayerIdx := int(curr.HasBallPlayerIdx)

	// Post-move press - an opponent who closed in during the move can
	// steal the ball before the holder can pass or shoot.
	var intercepted bool
	intercepted, seed = resolvePress(m, stateIdx, &next, seed)

	passTarget := int(moves[hasBallTeamIdx].Commands[0]&0xFF) % nPlayers

	if !intercepted && hasBallPlayerIdx != passTarget {
		intercepted = resolvePass(
			m, stateIdx, &next,
			hasBallTeamIdx, hasBallPlayerIdx, passTarget, seed)
	}
	// Phase 3: Handle `shoot` = command[1] - the ball travels in N_BALL_STEPS
	// towards the opposing goal and can be intercepted at each step
	if !intercepted && moves[hasBallTeamIdx].Commands[1] != 0 {
		resolveShot(m, stateIdx, &next, seed)
	}

	m.State = next
	m.States = append(m.States, next)
	m.StateIdx++

	if m.StateIdx == nRounds {
		m.Events = append(m.Events, MatchEvent{
			Kind: "match_ended", StateIdx: uint64(stateIdx),
		})
	}
}

// After the players move, every opponent within press range of the holder
// gets a skill roll to steal the ball before the pass leaves their feet.
func resolvePress(m *MatchEntry, stateIdx uint8, next *GameState, seed int64) (bool, int64) {
	holderTeam := int(next.HasBallTeamIdx)
	holderPlayer := int(next.HasBallPlayerIdx)
	ball := next.Teams[holderTeam].PlayerPositions[holderPlayer]

	for j := 0; j < nPlayers; j++ {
		opp := next.Teams[1-holderTeam].PlayerPositions[j]
		dx := opp[0] - ball[0]
		dy := opp[1] - ball[1]
		if dx*dx+dy*dy >= interceptionD2 {
			continue
		}

		holderSkill := m.PlayerStats[holderTeam][holderPlayer][0]
		pressSkill := m.PlayerStats[1-holderTeam][j][0]
		seed = rng(seed)
		denom := holderSkill + pressSkill
		if denom > 0 && seed%denom < pressSkill {
			next.HasBallTeamIdx = uint8(1 - holderTeam)
			next.HasBallPlayerIdx = uint8(j)
			m.Events = append(m.Events, MatchEvent{
				Kind:      "interception",
				StateIdx:  uint64(stateIdx),
				TeamIdx:   uint64(1 - holderTeam),
				PlayerIdx: uint64(j),
				X:         ball[0],
				Y:         ball[1],
			})
			return true, seed
		}
	}
	return false, seed
}

// The ball travels in N_BALL_STEPS towards the target and can be
// intercepted at each step. Returns whether the pass was intercepted.
func resolvePass(
	m *MatchEntry,
	stateIdx uint8,
	next *GameState,
	hasBallTeamIdx int,
	hasBallPlayerIdx int,
	passTarget int,
	seed int64,
) bool {
	ball := next.Teams[hasBallTeamIdx].PlayerPositions[hasBallPlayerIdx]

	// determine the trajectory of the ball
	dir := [2]int64{
		next.Teams[hasBallTeamIdx].PlayerPositions[passTarget][0] - ball[0],
		next.Teams[hasBallTeamIdx].PlayerPositions[passTarget][1] - ball[1],
	}

	for step := 0; step < nBallSteps; step++ {
		ball[0] += dir[0] / nBallSteps
		ball[1] += dir[1] / nBallSteps

		// for each player of the opposing team determine if they can
		// intercept the ball at this time step
		for j := 0; j < nPlayers; j++ {
			opp := next.Teams[1-hasBallTeamIdx].PlayerPositions[j]
			dx := ball[0] - opp[0]
			dy := ball[1] - opp[1]
			if dx*dx+dy*dy < interceptionD2 {
				// there's a potential to intercept based on skill ratio
				skill0 := m.PlayerStats[hasBallTeamIdx][hasBallPlayerIdx][0]
				skill1 := m.PlayerStats[1-hasBallTeamIdx][j][0]
				seed = rng(seed)
				denom := skill0 + skill1
				intercepted := denom > 0 && seed%denom < skill1

				if intercepted {
					// ball changes owner
					next.HasBallTeamIdx = uint8(1 - hasBallTeamIdx)
					next.HasBallPlayerIdx = uint8(j)
					m.Events = append(m.Events, MatchEvent{
						Kind:      "interception",
						StateIdx:  uint64(stateIdx),
						TeamIdx:   uint64(1 - hasBallTeamIdx),
						PlayerIdx: uint64(j),
						X:         ball[0],
						Y:         ball[1],
					})
					return true
				}

				break
			}
		}
	}

	// the pass was completed - the target player receives the ball
	next.HasBallPlayerIdx = uint8(passTarget)
	return false
}

func resolveShot(m *MatchEntry, stateIdx uint8, next *GameState, seed int64) {
	// The shooter is whoever holds the ball at this point - capture it
	// before an interception can flip possession.
	shooterTeam := int(next.HasBallTeamIdx)
	shooterPlayer := int(next.HasBallPlayerIdx)

	// goals only count when the shot is taken from the opposing half -
	// team 0 shoots towards FIELD_WIDTH, team 1 towards 0
	ball := next.Teams[shooterTeam].PlayerPositions[shooterPlayer]
	var inRange bool
	if shooterTeam == 0 {
		inRange = ball[0] > fieldWidth/2
	} else {
		inRange = ball[0] < fieldWidth/2
	}

	// determine the trajectory of the ball towards the center of the
	// opposing goal
	var goalX int64
	if shooterTeam == 0 {
		goalX = fieldWidth
	}
	dir := [2]int64{goalX - ball[0], fieldHeight/2 - ball[1]}

	intercepted := false
	for step := 0; step < nBallSteps; step++ {
		ball[0] += dir[0] / nBallSteps
		ball[1] += dir[1] / nBallSteps

		// for each player of the opposing team determine if they can
		// intercept the shot at this time step
		for j := 0; j < nPlayers; j++ {
			opp := next.Teams[1-shooterTeam].PlayerPositions[j]
			dx := ball[0] - opp[0]
			dy := ball[1] - opp[1]
			if dx*dx+dy*dy < interceptionD2 {
				// there's a potential to intercept based on skill ratio
				skill0 := m.PlayerStats[shooterTeam][shooterPlayer][0]
				skill1 := m.PlayerStats[1-shooterTeam][j][0]
				seed = rng(seed)
				denom := skill0 + skill1
				intercepted = denom > 0 && seed%denom < skill1

				if intercepted {
					// shot is intercepted - the defender seizes the ball
					next.HasBallTeamIdx = uint8(1 - shooterTeam)
					next.HasBallPlayerIdx = uint8(j)
					m.Events = append(m.Events, MatchEvent{
						Kind:      "interception",
						StateIdx:  uint64(stateIdx),
						TeamIdx:   uint64(1 - shooterTeam),
						PlayerIdx: uint64(j),
						X:         ball[0],
						Y:         ball[1],
					})
				}

				break
			}
		}

		if intercepted {
			break
		}
	}

	isGoal := false
	if !intercepted && inRange {
		// based on the skill ratio of the shooter and the goalkeeper,
		// determine if the shot is a goal
		shooterSkill := m.PlayerStats[shooterTeam][shooterPlayer][0]
		goalkeeperSkill := m.PlayerStats[1-shooterTeam][0][0]
		seed = rng(seed)
		denom := shooterSkill + goalkeeperSkill
		isGoal = denom > 0 && seed%denom < shooterSkill
	}

	m.Events = append(m.Events, MatchEvent{
		Kind:      "shot",
		StateIdx:  uint64(stateIdx),
		TeamIdx:   uint64(shooterTeam),
		PlayerIdx: uint64(shooterPlayer),
		X:         next.Teams[shooterTeam].PlayerPositions[shooterPlayer][0],
		Y:         next.Teams[shooterTeam].PlayerPositions[shooterPlayer][1],
		Goal:      isGoal,
	})

	if intercepted {
		return
	}

	if isGoal {
		next.Score[shooterTeam]++
	}

	// regardless if there's a goal or no - ball goes to the goalkeeper
	next.HasBallTeamIdx = uint8(1 - shooterTeam)
	next.HasBallPlayerIdx = 0
}

// ---- views ----

func GetMatchCount() int64 { return int64(len(matchIDs)) }

// GetMatchIDs renders a page of match indexes as a JSON array string.
func GetMatchIDs(offset, limit uint64) string {
	end := offset + limit
	if end > uint64(len(matchIDs)) {
		end = uint64(len(matchIDs))
	}
	var b strings.Builder
	b.WriteString("[")
	for i := offset; i < end; i++ {
		if i > offset {
			b.WriteString(",")
		}
		b.WriteString(u64str(matchIDs[i]))
	}
	b.WriteString("]")
	return b.String()
}

// GetMatch renders the whole match as a JSON string (snake_case keys,
// same shape the NEAR contract's MatchView produces).
func GetMatch(matchIdx uint64) string {
	m := matches[strconv.FormatUint(matchIdx, 10)]
	if m == nil {
		return "null"
	}

	var b strings.Builder
	b.WriteString(`{"match_idx":`)
	b.WriteString(u64str(m.MatchIdx))
	b.WriteString(`,"state_idx":`)
	b.WriteString(u64str(uint64(m.StateIdx)))
	b.WriteString(`,"agents":[`)
	for i, a := range m.Agents {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`"` + a + `"`)
	}
	b.WriteString(`],"player_stats":[`)
	for t := 0; t < nTeams; t++ {
		if t > 0 {
			b.WriteString(",")
		}
		b.WriteString("[")
		for i := 0; i < nPlayers; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("[")
			b.WriteString(i64str(m.PlayerStats[t][i][0]))
			b.WriteString(",")
			b.WriteString(i64str(m.PlayerStats[t][i][1]))
			b.WriteString("]")
		}
		b.WriteString("]")
	}
	b.WriteString(`],"state":`)
	jsonState(&b, m.State)
	b.WriteString(`,"states":[`)
	for i, s := range m.States {
		if i > 0 {
			b.WriteString(",")
		}
		jsonState(&b, s)
	}
	b.WriteString(`],"events":[`)
	for i, e := range m.Events {
		if i > 0 {
			b.WriteString(",")
		}
		jsonEvent(&b, e)
	}
	b.WriteString(`],"ended":`)
	if m.StateIdx >= nRounds {
		b.WriteString("true")
	} else {
		b.WriteString("false")
	}
	b.WriteString("}")
	return b.String()
}

func jsonState(b *strings.Builder, s GameState) {
	b.WriteString(`{"teams":[`)
	for t := 0; t < nTeams; t++ {
		if t > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"player_positions":[`)
		for i := 0; i < nPlayers; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString("[")
			b.WriteString(i64str(s.Teams[t].PlayerPositions[i][0]))
			b.WriteString(",")
			b.WriteString(i64str(s.Teams[t].PlayerPositions[i][1]))
			b.WriteString("]")
		}
		b.WriteString(`],"pass":`)
		b.WriteString(boolStr(s.Teams[t].Pass))
		b.WriteString(`,"passing_to":`)
		b.WriteString(u64str(s.Teams[t].PassingTo))
		b.WriteString(`,"shoot":`)
		b.WriteString(boolStr(s.Teams[t].Shoot))
		b.WriteString("}")
	}
	b.WriteString(`],"score":[`)
	b.WriteString(u64str(s.Score[0]))
	b.WriteString(",")
	b.WriteString(u64str(s.Score[1]))
	b.WriteString(`],"has_ball_team_idx":`)
	b.WriteString(u64str(uint64(s.HasBallTeamIdx)))
	b.WriteString(`,"has_ball_player_idx":`)
	b.WriteString(u64str(uint64(s.HasBallPlayerIdx)))
	b.WriteString("}")
}

func jsonEvent(b *strings.Builder, e MatchEvent) {
	b.WriteString(`{"kind":"`)
	b.WriteString(e.Kind)
	b.WriteString(`","state_idx":`)
	b.WriteString(u64str(e.StateIdx))
	b.WriteString(`,"team_idx":`)
	b.WriteString(u64str(e.TeamIdx))
	b.WriteString(`,"player_idx":`)
	b.WriteString(u64str(e.PlayerIdx))
	b.WriteString(`,"x":`)
	b.WriteString(i64str(e.X))
	b.WriteString(`,"y":`)
	b.WriteString(i64str(e.Y))
	b.WriteString(`,"goal":`)
	b.WriteString(boolStr(e.Goal))
	if e.HasData {
		b.WriteString(`,"data":["`)
		b.WriteString(hexEncode(e.Data[0][:]))
		b.WriteString(`","`)
		b.WriteString(hexEncode(e.Data[1][:]))
		b.WriteString(`"]`)
	}
	if e.HasMoves {
		b.WriteString(`,"moves":[`)
		for i, mv := range e.Moves {
			if i > 0 {
				b.WriteString(",")
			}
			jsonMove(b, mv)
		}
		b.WriteString("]")
	}
	b.WriteString("}")
}

func jsonMove(b *strings.Builder, mv Move) {
	b.WriteString(`{"state_idx":`)
	b.WriteString(u64str(mv.StateIdx))
	b.WriteString(`,"delta_player_positions":[`)
	for i := 0; i < nPlayers; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString("[")
		b.WriteString(i64str(mv.DeltaPlayerPositions[i][0]))
		b.WriteString(",")
		b.WriteString(i64str(mv.DeltaPlayerPositions[i][1]))
		b.WriteString("]")
	}
	b.WriteString(`],"commands":[`)
	b.WriteString(u64str(mv.Commands[0]))
	b.WriteString(",")
	b.WriteString(u64str(mv.Commands[1]))
	b.WriteString(`],"seed_part":"`)
	b.WriteString(hexEncode(mv.SeedPart[:]))
	b.WriteString(`"}`)
}

// Render renders a summary line for gnoweb/CLI browsing.
func Render(path string) string {
	return "Drakarys GAME_0 - " + i64str(GetMatchCount()) + " matches indexed"
}

// ---- encoding helpers ----

// abi.encodePacked-compatible 32-byte big-endian word packing so
// commitments produced by EVM-style tooling verify identically.
func packU256(v uint64, out *[]byte) {
	var b [32]byte
	for i := 0; i < 8; i++ {
		b[31-i] = byte(v >> (8 * i))
	}
	*out = append(*out, b[:]...)
}

func packI256(v int64, out *[]byte) {
	var b [32]byte
	if v < 0 {
		for i := range b {
			b[i] = 0xff
		}
	}
	u := uint64(v)
	for i := 0; i < 8; i++ {
		b[31-i] = byte(u >> (8 * i))
	}
	*out = append(*out, b[:]...)
}

// rng: same keccak-chained int64 sequence as every other deployment.
func rng(seed int64) int64 {
	var b [32]byte
	if seed < 0 {
		for i := range b {
			b[i] = 0xff
		}
	}
	u := uint64(seed)
	for i := 0; i < 8; i++ {
		b[31-i] = byte(u >> (8 * i))
	}
	h := keccak256.Sum256(b[:])
	var r int64
	for i := 0; i < 8; i++ {
		r = r<<8 | int64(h[i])
	}
	return r
}

// seedI64: low 64 bits of the seed word as int64 - `(x) as i64` in the
// Rust ports.
func seedI64(word [32]byte) int64 {
	var r int64
	for i := 24; i < 32; i++ {
		r = r<<8 | int64(word[i])
	}
	return r
}

// seedI64Half: `(x / 2) as i64` - low 64 bits of word>>1, i.e. bit 64 of
// the word becomes bit 63 of the result.
func seedI64Half(word [32]byte) int64 {
	r := uint64(seedI64(word)) >> 1
	r |= uint64(word[23]&1) << 63
	return int64(r)
}

func clamp(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// parseMove decodes the CSV produced by the relay:
// <stateIdx>,<dx0>,<dy0>,...,<dx10>,<dy10>,<cmd0>,<cmd1>,<seedHex>
// - 26 fields: decimal ints plus a 64-char hex seed word at the end.
func parseMove(s string) Move {
	parts := strings.Split(s, ",")
	if len(parts) != 26 {
		panic("move must have 26 fields")
	}
	var mv Move
	mv.StateIdx = uint64(atoi(parts[0]))
	for j := 0; j < nPlayers; j++ {
		mv.DeltaPlayerPositions[j][0] = int64(atoi(parts[1+j*2]))
		mv.DeltaPlayerPositions[j][1] = int64(atoi(parts[1+j*2+1]))
	}
	mv.Commands[0] = uint64(atoi(parts[23]))
	mv.Commands[1] = uint64(atoi(parts[24]))
	mv.SeedPart = hexDecode32(parts[25])
	return mv
}

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("bad number: " + s)
	}
	return n
}

func i64str(v int64) string  { return strconv.FormatInt(v, 10) }
func u64str(v uint64) string { return strconv.FormatUint(v, 10) }
func boolStr(v bool) string {
	if v {
		return "true"
	}
	return "false"
}

func hexEncode(b []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, 0, len(b)*2)
	for _, c := range b {
		out = append(out, digits[c>>4], digits[c&0x0f])
	}
	return string(out)
}

func hexDecode32(s string) [32]byte {
	var out [32]byte
	if len(s) != 64 {
		panic("commitment must be 32 bytes hex")
	}
	for i := 0; i < 32; i++ {
		out[i] = hexNibble(s[i*2])<<4 | hexNibble(s[i*2+1])
	}
	return out
}

func hexNibble(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	panic("bad hex")
}
