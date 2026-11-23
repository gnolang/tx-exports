package hearthboard

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"
	"unicode/utf8"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1xj5r20d9yy4hfap0x5w3p9nu4x27mekc8pscgs/ember"
)

const (
	open              = "Open"
	claimed           = "Claimed"
	review            = "In review"
	complete          = "Completed"
	cancelled         = "Cancelled"
	claimBlocks int64 = 20000
	maxEmber    int64 = 1000000
	pageSize          = 8
)

type Quest struct {
	ID       int64
	Title    string
	Brief    string
	Poster   address
	Solver   address
	Proof    string
	Bounty   int64
	Tips     int64
	State    string
	Deadline int64
}

type Score struct {
	Solver address
	Solved int64
}

var (
	quests    avl.Tree
	scores    avl.Tree
	leaders   []Score
	latest    int64
	fulfilled int64
	escrowed  int64
)

func Post(cur realm, title, brief string, bounty int64) int64 {
	poster := wallet(0, cur)
	title = text(title, 80)
	brief = text(brief, 800)
	if bounty < 0 || bounty > maxEmber || bounty > 9223372036854775807-escrowed {
		panic("invalid bounty")
	}
	if bounty > 0 {
		ember.TransferFrom(cross(cur), poster, cur.Address(), bounty)
	}
	latest++
	q := &Quest{ID: latest, Title: title, Brief: brief, Poster: poster, Bounty: bounty, State: open}
	quests.Set(key(q.ID), q)
	escrowed += bounty
	emit("QuestPosted", q, poster)
	return q.ID
}

func Claim(cur realm, id int64) {
	solver := wallet(0, cur)
	q := mustQuest(id)
	if solver == q.Poster || !available(q) {
		panic("quest is not claimable by this wallet")
	}
	q.Solver, q.Proof, q.State = solver, "", claimed
	q.Deadline = runtime.ChainHeight() + claimBlocks
	emit("QuestClaimed", q, solver)
}

func Release(cur realm, id int64) {
	solver := wallet(0, cur)
	q := mustQuest(id)
	if solver != q.Solver || !active(q) {
		panic("only the active solver can release")
	}
	q.Solver, q.Proof, q.State, q.Deadline = "", "", open, 0
	emit("QuestReleased", q, solver)
}

func Submit(cur realm, id int64, proof string) {
	solver := wallet(0, cur)
	q := mustQuest(id)
	if q.State != claimed || solver != q.Solver || expired(q) {
		panic("only the active solver can submit once")
	}
	q.Proof, q.State = text(proof, 800), review
	emit("ProofSubmitted", q, solver)
}

func Complete(cur realm, id int64, solver address, proof string) {
	poster := wallet(0, cur)
	q := mustQuest(id)
	if poster != q.Poster || q.State != review || q.Solver != solver || q.Proof != proof {
		panic("only the poster can approve the current submission")
	}
	if q.Bounty > 0 {
		ember.Transfer(cross(cur), solver, q.Bounty)
	}
	escrowed -= q.Bounty
	q.State = complete
	fulfilled++
	recordSolve(solver)
	emit("QuestCompleted", q, solver)
}

func Cancel(cur realm, id int64) {
	poster := wallet(0, cur)
	q := mustQuest(id)
	if poster != q.Poster || !available(q) {
		panic("only the poster can cancel an open or expired quest")
	}
	if q.Bounty > 0 {
		ember.Transfer(cross(cur), poster, q.Bounty)
	}
	escrowed -= q.Bounty
	q.Solver, q.Proof, q.State, q.Deadline = "", "", cancelled, 0
	emit("QuestCancelled", q, poster)
}

func Tip(cur realm, id int64, recipient address, amount int64) {
	tipper := wallet(0, cur)
	q := mustQuest(id)
	if q.State == cancelled || recipient == tipper || (recipient != q.Poster && (q.State != complete || recipient != q.Solver)) {
		panic("tip a different wallet: the poster or the completed solver")
	}
	if amount < 1 || amount > maxEmber || amount > 9223372036854775807-q.Tips {
		panic("invalid tip")
	}
	ember.TransferFrom(cross(cur), tipper, recipient, amount)
	q.Tips += amount
	chain.Emit("QuestTipped", "id", key(id), "from", tipper.String(), "to", recipient.String(), "amount", key(amount))
}

func EscrowAddress() address { return chain.PackageAddress(boardPath) }
func Escrowed() int64        { return escrowed }

func wallet(_ int, rlm realm) address {
	caller := rlm.Previous()
	if !caller.IsUserCall() {
		panic("use a direct wallet call")
	}
	return caller.Address()
}

func key(n int64) string { return strconv.FormatInt(n, 10) }

func getQuest(id int64) *Quest {
	val := quests.Get(key(id))
	if val == nil {
		return nil
	}
	return val.(*Quest)
}

func mustQuest(id int64) *Quest {
	q := getQuest(id)
	if q == nil {
		panic("quest not found")
	}
	return q
}

func active(q *Quest) bool    { return q.State == claimed || q.State == review }
func expired(q *Quest) bool   { return active(q) && runtime.ChainHeight() >= q.Deadline }
func available(q *Quest) bool { return q.State == open || expired(q) }

func text(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > limit || !utf8.ValidString(value) {
		panic("text is empty, too long or invalid UTF-8")
	}
	for _, c := range value {
		if c < ' ' && c != '\n' && c != '\t' {
			panic("text contains control characters")
		}
	}
	return value
}

func emit(event string, q *Quest, actor address) {
	chain.Emit(event, "id", key(q.ID), "actor", actor.String())
}

func recordSolve(solver address) {
	score := Score{Solver: solver, Solved: 1}
	old := scores.Get(solver.String())
	if old != nil {
		score.Solved += old.(int64)
	}
	scores.Set(solver.String(), score.Solved)
	for i, entry := range leaders {
		if entry.Solver == solver {
			leaders = append(leaders[:i], leaders[i+1:]...)
			break
		}
	}
	leaders = append(leaders, score)
	for i := len(leaders) - 1; i > 0; i-- {
		prev := leaders[i-1]
		if prev.Solved > score.Solved || (prev.Solved == score.Solved && prev.Solver.String() < solver.String()) {
			break
		}
		leaders[i], leaders[i-1] = prev, score
	}
	if len(leaders) > pageSize {
		leaders = leaders[:pageSize]
	}
}
