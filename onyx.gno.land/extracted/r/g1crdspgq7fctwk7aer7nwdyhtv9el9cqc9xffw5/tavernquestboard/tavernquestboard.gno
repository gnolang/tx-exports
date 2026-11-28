// Tavern Quest Board — papan quest ala tavern RPG di Gno.land.
//
// Siapa pun bisa memposting quest dengan reward GNOT (ugnot) yang di-escrow
// ke realm ini. Adventurer mengambil quest, mengirim bukti pengerjaan,
// poster menyetujui, lalu reward cair otomatis dari escrow ke adventurer.
// Leaderboard mencatat adventurer berdasarkan quest selesai + total reward.
//
// Lifecycle quest: open -> taken -> submitted -> done
//                  open -> cancelled (refund ke poster, hanya sebelum diambil)
//                  submitted -> taken (poster menolak bukti, boleh kirim ulang)
package tavernquestboard

import (
	"strconv"
	"strings"

	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
)

const denom = "ugnot"

type Quest struct {
	ID            int
	Title         string
	Desc          string
	Poster        address
	Reward        int64 // ugnot, di-escrow di realm ini
	Status        string
	Taker         address
	Proof         string
	CreatedHeight int64
}

const (
	statusOpen      = "open"
	statusTaken     = "taken"
	statusSubmitted = "submitted"
	statusDone      = "done"
	statusCancelled = "cancelled"
)

var (
	quests      []*Quest
	escrowTotal int64 // jumlah ugnot yang masih terkunci untuk quest aktif
	completed   = make(map[address]int)
	earned      = make(map[address]int64)
)

// PostQuest membuat quest baru. Reward diambil dari coin ugnot yang dikirim
// bersama pemanggilan ini (escrow). Mengembalikan ID quest.
func PostQuest(cur realm, title string, desc string) int {
	if !cur.Previous().IsUserCall() {
		panic("only user-call (maketx call) accepted")
	}
	if strings.TrimSpace(title) == "" {
		panic("title must not be empty")
	}
	sent := unsafe.OriginSend()
	reward := sent.AmountOf(denom)
	if reward <= 0 {
		panic("quest reward must be a positive ugnot amount sent with the call")
	}
	if len(sent) != 1 {
		panic("only ugnot is accepted as quest reward")
	}

	escrowTotal += reward
	q := &Quest{
		ID:            len(quests) + 1,
		Title:         title,
		Desc:          desc,
		Poster:        cur.Previous().Address(),
		Reward:        reward,
		Status:        statusOpen,
		CreatedHeight: runtime.ChainHeight(),
	}
	quests = append(quests, q)
	return q.ID
}

// TakeQuest mengambil quest yang masih open. Poster tidak boleh mengambil
// quest-nya sendiri.
func TakeQuest(cur realm, id int) {
	q := getQuest(id)
	caller := cur.Previous().Address()
	if q.Status != statusOpen {
		panic("quest is not open")
	}
	if caller == q.Poster {
		panic("poster cannot take their own quest")
	}
	q.Taker = caller
	q.Status = statusTaken
}

// SubmitProof mengirim bukti pengerjaan (mis. link) untuk quest yang sedang
// dikerjakan pemanggil.
func SubmitProof(cur realm, id int, proof string) {
	q := getQuest(id)
	caller := cur.Previous().Address()
	if q.Status != statusTaken {
		panic("quest is not in taken state")
	}
	if caller != q.Taker {
		panic("only the adventurer who took the quest can submit proof")
	}
	if strings.TrimSpace(proof) == "" {
		panic("proof must not be empty")
	}
	q.Proof = proof
	q.Status = statusSubmitted
}

// ApproveQuest menyetujui bukti dan mencairkan reward escrow ke adventurer.
// Hanya poster, hanya untuk quest berstatus submitted.
func ApproveQuest(cur realm, id int) {
	q := getQuest(id)
	caller := cur.Previous().Address()
	if caller != q.Poster {
		panic("only the quest poster can approve")
	}
	if q.Status != statusSubmitted {
		panic("quest has no submitted proof to approve")
	}

	// Effects sebelum interaction (CEI): ubah state + accounting dulu.
	q.Status = statusDone
	escrowTotal -= q.Reward
	completed[q.Taker]++
	earned[q.Taker] += q.Reward

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), q.Taker, chain.NewCoins(chain.NewCoin(denom, q.Reward)))
}

// RejectProof menolak bukti yang dikirim; quest kembali ke status taken agar
// adventurer bisa mengirim bukti baru. Hanya poster.
func RejectProof(cur realm, id int) {
	q := getQuest(id)
	caller := cur.Previous().Address()
	if caller != q.Poster {
		panic("only the quest poster can reject proof")
	}
	if q.Status != statusSubmitted {
		panic("quest has no submitted proof to reject")
	}
	q.Proof = ""
	q.Status = statusTaken
}

// CancelQuest membatalkan quest yang belum diambil dan mengembalikan escrow
// ke poster. Hanya poster, hanya saat status open.
func CancelQuest(cur realm, id int) {
	q := getQuest(id)
	caller := cur.Previous().Address()
	if caller != q.Poster {
		panic("only the quest poster can cancel")
	}
	if q.Status != statusOpen {
		panic("only an open (not yet taken) quest can be cancelled")
	}

	q.Status = statusCancelled
	escrowTotal -= q.Reward

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), q.Poster, chain.NewCoins(chain.NewCoin(denom, q.Reward)))
}

// QuestCount mengembalikan jumlah quest yang pernah dibuat.
func QuestCount() int {
	return len(quests)
}

// EscrowTotal mengembalikan total ugnot yang masih terkunci di escrow.
func EscrowTotal() int64 {
	return escrowTotal
}

func getQuest(id int) *Quest {
	if id < 1 || id > len(quests) {
		panic("quest not found")
	}
	return quests[id-1]
}

// sanitize membersihkan teks user sebelum masuk markdown Render.
func sanitize(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	return s
}

func shortAddr(a address) string {
	s := string(a)
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}

// Render menampilkan papan quest (path ""), detail quest ("quest/<id>"),
// atau leaderboard adventurer ("leaderboard").
func Render(path string) string {
	if path == "leaderboard" {
		return renderLeaderboard()
	}
	if strings.HasPrefix(path, "quest/") {
		idStr := strings.TrimPrefix(path, "quest/")
		id, err := strconv.Atoi(idStr)
		if err != nil || id < 1 || id > len(quests) {
			return "# Quest tidak ditemukan\n\nID quest tidak valid.\n"
		}
		return renderQuest(quests[id-1])
	}
	return renderBoard()
}

func renderBoard() string {
	out := "# Tavern Quest Board\n\n"
	out += "Papan quest para gnome. Posting quest dengan reward GNOT (escrow), " +
		"ambil quest, kirim bukti, reward cair otomatis setelah disetujui poster.\n\n"
	out += "Total quest: " + strconv.Itoa(len(quests)) +
		" | Escrow terkunci: " + strconv.FormatInt(escrowTotal, 10) + " ugnot\n\n"
	out += "## Quest Terbuka\n\n"
	open := 0
	for _, q := range quests {
		if q.Status == statusOpen {
			open++
			out += "- **#" + strconv.Itoa(q.ID) + " " + sanitize(q.Title) + "** — " +
				strconv.FormatInt(q.Reward, 10) + " ugnot, oleh `" + shortAddr(q.Poster) + "`\n"
		}
	}
	if open == 0 {
		out += "_Belum ada quest terbuka. Jadilah yang pertama memposting!_\n"
	}
	out += "\n## Semua Quest\n\n"
	out += "| ID | Judul | Reward (ugnot) | Status | Poster | Adventurer |\n"
	out += "|----|-------|----------------|--------|--------|------------|\n"
	for _, q := range quests {
		taker := "-"
		if q.Taker != "" {
			taker = "`" + shortAddr(q.Taker) + "`"
		}
		out += "| " + strconv.Itoa(q.ID) + " | " + sanitize(q.Title) + " | " +
			strconv.FormatInt(q.Reward, 10) + " | " + q.Status + " | `" +
			shortAddr(q.Poster) + "` | " + taker + " |\n"
	}
	out += "\nLihat [leaderboard](leaderboard) adventurer.\n"
	return out
}

func renderQuest(q *Quest) string {
	out := "# Quest #" + strconv.Itoa(q.ID) + ": " + sanitize(q.Title) + "\n\n"
	out += sanitize(q.Desc) + "\n\n"
	out += "- **Reward:** " + strconv.FormatInt(q.Reward, 10) + " ugnot\n"
	out += "- **Status:** " + q.Status + "\n"
	out += "- **Poster:** `" + string(q.Poster) + "`\n"
	if q.Taker != "" {
		out += "- **Adventurer:** `" + string(q.Taker) + "`\n"
	}
	if q.Proof != "" {
		out += "- **Bukti:** " + sanitize(q.Proof) + "\n"
	}
	out += "- **Dibuat pada block:** " + strconv.FormatInt(q.CreatedHeight, 10) + "\n"
	return out
}

func renderLeaderboard() string {
	out := "# Leaderboard Adventurer\n\n"
	if len(completed) == 0 {
		out += "_Belum ada quest yang selesai._\n"
		return out
	}
	// Kumpulkan + urutkan: earned desc, lalu completed desc, lalu alamat.
	addrs := make([]address, 0, len(completed))
	for a := range completed {
		addrs = append(addrs, a)
	}
	for i := 0; i < len(addrs); i++ {
		for j := i + 1; j < len(addrs); j++ {
			a, b := addrs[i], addrs[j]
			if earned[b] > earned[a] ||
				(earned[b] == earned[a] && completed[b] > completed[a]) ||
				(earned[b] == earned[a] && completed[b] == completed[a] && string(b) < string(a)) {
				addrs[i], addrs[j] = b, a
			}
		}
	}
	out += "| Rank | Adventurer | Quest Selesai | Total Reward (ugnot) |\n"
	out += "|------|------------|---------------|----------------------|\n"
	for i, a := range addrs {
		out += "| " + strconv.Itoa(i+1) + " | `" + shortAddr(a) + "` | " +
			strconv.Itoa(completed[a]) + " | " + strconv.FormatInt(earned[a], 10) + " |\n"
	}
	return out
}
