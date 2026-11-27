package tavernledger

import (
	"chain"
	"strconv"
)

const (
	StatusOpen      = "open"
	StatusClaimed   = "claimed"
	StatusSubmitted = "submitted"
	StatusApproved  = "approved"
	StatusCancelled = "cancelled"
)

const (
	EventQuestCreated   = "QuestCreated"
	EventQuestClaimed   = "QuestClaimed"
	EventProofSubmitted = "ProofSubmitted"
	EventQuestApproved  = "QuestApproved"
	EventQuestRejected  = "QuestRejected"
	EventQuestCancelled = "QuestCancelled"
)

type Quest struct {
	ID          int
	Title       string
	Description string
	Creator     address
	Reward      int
	Status      string
	Hunter      address
	Proof       string
}

var (
	quests  []Quest
	points  = map[address]int{}
	players []address
)

func CreateQuest(cur realm, title string, description string, reward int) int {
	if len(title) == 0 {
		panic("title is required")
	}
	if len(title) > 80 {
		panic("title is too long")
	}
	if len(description) > 280 {
		panic("description is too long")
	}
	if reward <= 0 {
		panic("reward must be positive")
	}
	if reward > 1000 {
		panic("reward is too large")
	}

	id := len(quests) + 1
	quests = append(quests, Quest{
		ID:          id,
		Title:       title,
		Description: description,
		Creator:     cur.Previous().Address(),
		Reward:      reward,
		Status:      StatusOpen,
	})

	chain.Emit(EventQuestCreated, "id", strconv.Itoa(id), "title", title, "reward", strconv.Itoa(reward))
	return id
}

func ClaimQuest(cur realm, id int) bool {
	q := questByID(id)
	if q.Status != StatusOpen {
		panic("quest is not open")
	}
	caller := cur.Previous().Address()
	if caller == q.Creator {
		panic("creator cannot claim their own quest")
	}
	q.Hunter = caller
	q.Status = StatusClaimed
	chain.Emit(EventQuestClaimed, "id", strconv.Itoa(id), "hunter", caller.String())
	return true
}

func SubmitProof(cur realm, id int, proof string) bool {
	q := questByID(id)
	if q.Status != StatusClaimed {
		panic("quest is not claimed")
	}
	if cur.Previous().Address() != q.Hunter {
		panic("only the hunter can submit proof")
	}
	if len(proof) == 0 {
		panic("proof is required")
	}
	if len(proof) > 500 {
		panic("proof is too long")
	}
	q.Proof = proof
	q.Status = StatusSubmitted
	chain.Emit(EventProofSubmitted, "id", strconv.Itoa(id), "hunter", q.Hunter.String())
	return true
}

func ApproveQuest(cur realm, id int) bool {
	q := questByID(id)
	if q.Status != StatusSubmitted {
		panic("quest has no submitted proof")
	}
	if cur.Previous().Address() != q.Creator {
		panic("only the creator can approve")
	}
	q.Status = StatusApproved
	awardPoints(q.Hunter, q.Reward)
	chain.Emit(EventQuestApproved, "id", strconv.Itoa(id), "hunter", q.Hunter.String(), "reward", strconv.Itoa(q.Reward))
	return true
}

func RejectQuest(cur realm, id int) bool {
	q := questByID(id)
	if q.Status != StatusSubmitted {
		panic("quest has no submitted proof")
	}
	if cur.Previous().Address() != q.Creator {
		panic("only the creator can reject")
	}
	q.Status = StatusClaimed
	q.Proof = ""
	chain.Emit(EventQuestRejected, "id", strconv.Itoa(id), "hunter", q.Hunter.String())
	return true
}

func CancelQuest(cur realm, id int) bool {
	q := questByID(id)
	if q.Status != StatusOpen {
		panic("only an open quest can be cancelled")
	}
	if cur.Previous().Address() != q.Creator {
		panic("only the creator can cancel")
	}
	q.Status = StatusCancelled
	chain.Emit(EventQuestCancelled, "id", strconv.Itoa(id))
	return true
}

func QuestCount() int {
	return len(quests)
}

func PointsOf(addr address) int {
	return points[addr]
}

func GetQuest(id int) string {
	if id <= 0 || id > len(quests) {
		return "quest not found"
	}
	q := quests[id-1]
	return "#" + strconv.Itoa(q.ID) + " " + q.Title + " | status: " + q.Status + " | reward: " + strconv.Itoa(q.Reward) + " points | creator: " + q.Creator.String() + " | hunter: " + hunterLabel(q) + " | proof: " + proofLabel(q)
}

func Render(_ string) string {
	out := "# Tavern Ledger\n\n"
	out += "A tiny on-chain quest board for communities. Create a quest, let another builder claim it, submit proof, and award points after approval.\n\n"
	out += "## How it works\n\n"
	out += "1. `CreateQuest(title, description, reward)` opens a quest.\n"
	out += "2. `ClaimQuest(id)` lets a different address take the quest.\n"
	out += "3. `SubmitProof(id, proof)` records a proof link or note.\n"
	out += "4. `ApproveQuest(id)` awards the quest points to the hunter.\n\n"
	out += "## Quests\n\n"
	if len(quests) == 0 {
		out += "No quests yet. Create the first one.\n\n"
	} else {
		out += "| ID | Quest | Reward | Status | Hunter |\n"
		out += "| --- | --- | ---: | --- | --- |\n"
		for i := 0; i < len(quests); i++ {
			q := quests[i]
			out += "| " + strconv.Itoa(q.ID) + " | " + clean(q.Title) + " | " + strconv.Itoa(q.Reward) + " | " + q.Status + " | " + hunterLabel(q) + " |\n"
		}
		out += "\n"
	}
	out += "## Leaderboard\n\n"
	if len(players) == 0 {
		out += "No points awarded yet.\n"
	} else {
		sorted := sortedPlayers()
		for i := 0; i < len(sorted); i++ {
			out += strconv.Itoa(i+1) + ". `" + sorted[i].String() + "` — " + strconv.Itoa(points[sorted[i]]) + " points\n"
		}
	}
	return out
}

func questByID(id int) *Quest {
	if id <= 0 || id > len(quests) {
		panic("quest not found")
	}
	return &quests[id-1]
}

func awardPoints(addr address, reward int) {
	if points[addr] == 0 {
		players = append(players, addr)
	}
	points[addr] += reward
}

func sortedPlayers() []address {
	sorted := make([]address, len(players))
	for i := 0; i < len(players); i++ {
		sorted[i] = players[i]
	}
	for i := 1; i < len(sorted); i++ {
		current := sorted[i]
		j := i - 1
		for j >= 0 && points[sorted[j]] < points[current] {
			sorted[j+1] = sorted[j]
			j--
		}
		sorted[j+1] = current
	}
	return sorted
}

func hunterLabel(q Quest) string {
	if q.Status == StatusOpen || q.Status == StatusCancelled {
		return "-"
	}
	return q.Hunter.String()
}

func proofLabel(q Quest) string {
	if len(q.Proof) == 0 {
		return "-"
	}
	return q.Proof
}

func clean(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i : i+1]
		if c == "|" {
			out += "/"
		} else if c == "\n" || c == "\r" {
			out += " "
		} else {
			out += c
		}
	}
	return out
}
