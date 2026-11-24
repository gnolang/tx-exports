// Package mequest is MeQuest: quests that verify themselves.
//
// Projects lock GNOT rewards in this realm when they create a quest.
// Coins can only leave through a verified claim, a split settle, or a
// refund of the unclaimed remainder to the funder after expiry.
// Winners get a soulbound rarity card (Common/Rare/Epic/Legendary).
package mqdev2

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

// ---------- rules ----------

const (
	Common    = 1
	Rare      = 2
	Epic      = 3
	Legendary = 4

	KindManual = "manual" // project reviews a proof
	KindPush   = "push"   // partner realm calls Complete
	KindHold   = "hold"   // wallet holds at least Arg ugnot

	PayFixed = "fixed" // style A: Reward per winner, paid on claim
	PaySplit = "split" // style B: pool split equally after expiry

	DailyCap = 10
	Season   = "S1"
	daySecs  = 86400
)

var (
	admin     address = "g1hwcp3aah5ehwq7zvz74c4x5nzewtgz2qmwjj0l"
	supplyCap         = map[int]int{Common: 0, Rare: 500, Epic: 100, Legendary: 10} // 0 = unlimited
	cardPts           = map[int]int64{Common: 10, Rare: 50, Epic: 200, Legendary: 1000}
	rarityName        = map[int]string{Common: "Common", Rare: "Rare", Epic: "Epic", Legendary: "Legendary"}
	rankName          = map[int]string{0: "Newcomer", Common: "Rookie", Rare: "Explorer", Epic: "Pathfinder", Legendary: "Legend"}
)

// ---------- state ----------

type Card struct {
	QuestID int
	Title   string
	Rarity  int
	Serial  int
	Season  string
	At      int64
}

type Quest struct {
	ID      int
	Title   string
	Desc    string
	Funder  address
	Rarity  int
	Kind    string
	Arg     string // hold: min ugnot; push: partner pkg path
	Pay     string
	Reward  int64 // fixed: ugnot per winner
	Pool    int64 // ugnot still locked for this quest
	Funded  int64
	Max     int
	Expires int64
	Settled bool
	Winners []address
	won     map[address]bool
	pending map[address]string
}

var (
	quests   []*Quest
	cards    = map[address][]Card{}
	points   = map[address]int64{}
	daily    = map[string]int{}
	projects = map[address]bool{}
	players  []address
	log      []string
)

// ---------- projects ----------

// CreateQuest locks the sent ugnot as the quest pool. Send coins with the tx.
func CreateQuest(cur realm, title, desc string, rarity int, kind, arg, pay string, max int, days int) int {
	requireWallet(cur)
	funder := cur.Previous().Address()
	if rarity < Common || rarity > Legendary {
		panic("bad rarity")
	}
	if rarity >= Epic && !projects[funder] && funder != admin {
		panic("only approved projects can create Epic or Legendary quests")
	}
	if kind != KindManual && kind != KindPush && kind != KindHold {
		panic("bad kind")
	}
	if kind == KindHold {
		if _, err := strconv.ParseInt(arg, 10, 64); err != nil {
			panic("hold quests need a ugnot amount as arg")
		}
	}
	if pay != PayFixed && pay != PaySplit {
		panic("bad pay style")
	}
	if pay == PaySplit && rarity < Epic && kind != KindPush {
		panic("split pay is for Epic/Legendary or partner quests")
	}
	if max < 1 || (supplyCap[rarity] > 0 && max > supplyCap[rarity]) {
		panic("max winners out of range for this rarity")
	}
	if days < 1 || days > 90 {
		panic("days must be 1-90")
	}
	if strings.TrimSpace(title) == "" {
		panic("title required")
	}
	sent := unsafe.OriginSend().AmountOf("ugnot")
	if sent <= 0 {
		panic("send ugnot to fund the pool")
	}
	q := &Quest{
		ID: len(quests) + 1, Title: title, Desc: desc, Funder: funder,
		Rarity: rarity, Kind: kind, Arg: arg, Pay: pay,
		Pool: sent, Funded: sent, Max: max,
		Expires: time.Now().Unix() + int64(days)*daySecs,
		won: map[address]bool{}, pending: map[address]string{},
	}
	if pay == PayFixed {
		if sent%int64(max) != 0 {
			panic("pool must divide evenly by max winners")
		}
		q.Reward = sent / int64(max)
	}
	quests = append(quests, q)
	note("quest #" + itoa(q.ID) + " created, pool " + gnot(sent))
	return q.ID
}

// Review approves or rejects a manual proof. Funder or admin only.
func Review(cur realm, id int, wallet address, ok bool) {
	q := mustQuest(id)
	caller := cur.Previous().Address()
	if caller != q.Funder && caller != admin {
		panic("only the quest funder can review")
	}
	if _, has := q.pending[wallet]; !has {
		panic("no pending proof")
	}
	delete(q.pending, wallet)
	if ok {
		award(cur, q, wallet)
	} else {
		note("quest #" + itoa(id) + " proof rejected for " + short(wallet))
	}
}

// Refund returns the unclaimed pool of an expired fixed quest to its funder.
func Refund(cur realm, id int) {
	q := mustQuest(id)
	if q.Pay != PayFixed {
		panic("split quests use Settle")
	}
	if time.Now().Unix() < q.Expires {
		panic("quest still running: pool is locked")
	}
	if q.Pool == 0 {
		panic("nothing to refund")
	}
	amt := q.Pool
	q.Pool = 0
	send(cur, q.Funder, amt)
	note("quest #" + itoa(id) + " refunded " + gnot(amt) + " to funder")
}

// Settle pays a split quest after expiry. Anyone can call it.
func Settle(cur realm, id int) {
	q := mustQuest(id)
	if q.Pay != PaySplit || q.Settled {
		panic("not a split quest or already settled")
	}
	if time.Now().Unix() < q.Expires {
		panic("quest still running")
	}
	q.Settled = true
	n := int64(len(q.Winners))
	if n > 0 {
		share := q.Pool / n
		for _, w := range q.Winners {
			send(cur, w, share)
			q.Pool -= share
		}
		note("quest #" + itoa(id) + " split " + gnot(share) + " x " + itoa(int(n)))
	}
	if q.Pool > 0 {
		left := q.Pool
		q.Pool = 0
		send(cur, q.Funder, left)
	}
}

// ---------- questers ----------

// Claim runs the quest's own check on the caller and pays if it passes.
func Claim(cur realm, id int) {
	requireWallet(cur)
	q := mustQuest(id)
	user := cur.Previous().Address()
	switch q.Kind {
	case KindHold:
		min, _ := strconv.ParseInt(q.Arg, 10, 64)
		bal := banker.NewReadonlyBanker().GetCoin(user, "ugnot")
		if bal < min {
			panic("check failed: hold at least " + gnot(min))
		}
	case KindManual:
		panic("this quest needs a proof: use Submit")
	case KindPush:
		panic("finish this quest on the partner app: " + q.Arg)
	}
	award(cur, q, user)
}

// Submit sends a proof (link or text) for a manual quest.
func Submit(cur realm, id int, proof string) {
	requireWallet(cur)
	q := mustQuest(id)
	user := cur.Previous().Address()
	if q.Kind != KindManual {
		panic("not a manual quest")
	}
	open(q, user)
	if len(proof) == 0 || len(proof) > 280 {
		panic("proof must be 1-280 chars")
	}
	q.pending[user] = proof
	note("quest #" + itoa(id) + " proof submitted by " + short(user))
}

// Complete is called by the partner realm named in a push quest.
func Complete(cur realm, id int, wallet address) {
	q := mustQuest(id)
	if q.Kind != KindPush {
		panic("not a push quest")
	}
	if cur.Previous().PkgPath() != q.Arg {
		panic("only " + q.Arg + " can complete this quest")
	}
	award(cur, q, wallet)
}

// ---------- admin ----------

func ApproveProject(cur realm, p address, on bool) {
	onlyAdmin(cur)
	projects[p] = on
}

// Revoke removes a card from a cheater wallet.
func Revoke(cur realm, wallet address, id int) {
	onlyAdmin(cur)
	list := cards[wallet]
	for i, c := range list {
		if c.QuestID == id {
			cards[wallet] = append(list[:i], list[i+1:]...)
			points[wallet] -= cardPts[c.Rarity]
			note("card from quest #" + itoa(id) + " revoked from " + short(wallet))
			return
		}
	}
	panic("wallet has no card from that quest")
}

// ---------- read-only checks (other realms can call these) ----------

func HasCard(wallet address, id int) bool {
	for _, c := range cards[wallet] {
		if c.QuestID == id {
			return true
		}
	}
	return false
}

func BestRarity(wallet address) int {
	best := 0
	for _, c := range cards[wallet] {
		if c.Rarity > best {
			best = c.Rarity
		}
	}
	return best
}

func HasRarity(wallet address, min int) bool { return BestRarity(wallet) >= min }
func PointsOf(wallet address) int64          { return points[wallet] }
func CardCount(wallet address) int           { return len(cards[wallet]) }

// ---------- internals ----------

func award(cur realm, q *Quest, user address) {
	open(q, user)
	if q.Rarity == Legendary && BestRarity(user) < Epic {
		panic("Legendary needs an Epic card first")
	}
	if len(q.Winners) >= q.Max {
		panic("all winner slots are taken")
	}
	day := strconv.FormatInt(time.Now().Unix()/daySecs, 10)
	key := string(user) + ":" + day
	if daily[key] >= DailyCap {
		panic("daily cap reached: 10 claims per day")
	}
	daily[key]++

	q.won[user] = true
	q.Winners = append(q.Winners, user)
	if _, seen := points[user]; !seen {
		players = append(players, user)
	}
	cards[user] = append(cards[user], Card{
		QuestID: q.ID, Title: q.Title, Rarity: q.Rarity,
		Serial: len(q.Winners), Season: Season, At: time.Now().Unix(),
	})
	points[user] += cardPts[q.Rarity]

	msg := short(user) + " won " + rarityName[q.Rarity] + " #" + itoa(len(q.Winners)) + " on quest #" + itoa(q.ID)
	if q.Pay == PayFixed {
		q.Pool -= q.Reward
		send(cur, user, q.Reward)
		msg += ", paid " + gnot(q.Reward)
	}
	note(msg)
}

func open(q *Quest, user address) {
	if time.Now().Unix() >= q.Expires {
		panic("quest expired")
	}
	if q.won[user] {
		panic("already claimed: one win per wallet")
	}
}

func send(cur realm, to address, amt int64) {
	if amt <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{{"ugnot", amt}})
}

// requireWallet blocks calls routed through other realms (anti-farming bots,
// and makes sure sent coins really came from the caller).
func requireWallet(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("call this directly from your wallet")
	}
}

func onlyAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func mustQuest(id int) *Quest {
	if id < 1 || id > len(quests) {
		panic("quest not found")
	}
	return quests[id-1]
}

func note(s string) {
	log = append(log, s)
	if len(log) > 50 {
		log = log[len(log)-50:]
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func gnot(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strings.TrimRight(strconv.FormatInt(frac+1000000, 10)[1:], "0")
	return strconv.FormatInt(whole, 10) + "." + f + " GNOT"
}

func short(a address) string {
	s := string(a)
	if len(s) < 12 {
		return s
	}
	return s[:7] + "…" + s[len(s)-4:]
}

// ---------- pages ----------

func Render(path string) string {
	switch {
	case path == "":
		return renderBoard()
	case strings.HasPrefix(path, "q/"):
		id, err := strconv.Atoi(path[2:])
		if err != nil || id < 1 || id > len(quests) {
			return "quest not found"
		}
		return renderQuest(quests[id-1])
	case strings.HasPrefix(path, "p/"):
		return renderPassport(address(path[2:]))
	case path == "top":
		return renderTop()
	}
	return "404"
}

func renderBoard() string {
	s := "# MeQuest\n_Quests that verify themselves._ Season " + Season + "\n\n"
	s += "[Leaderboard](:top)\n\n## Quests\n\n"
	if len(quests) == 0 {
		s += "No quests yet.\n"
	}
	for i := len(quests) - 1; i >= 0; i-- {
		q := quests[i]
		s += "- [#" + itoa(q.ID) + " " + q.Title + "](:q/" + itoa(q.ID) + ") · " + rarityName[q.Rarity] +
			" · " + itoa(len(q.Winners)) + "/" + itoa(q.Max) + " claimed · pool " + gnot(q.Pool) + " left\n"
	}
	s += "\n## Live feed\n\n"
	for i := len(log) - 1; i >= 0 && i >= len(log)-10; i-- {
		s += "- " + log[i] + "\n"
	}
	return s
}

func renderQuest(q *Quest) string {
	s := "# #" + itoa(q.ID) + " " + q.Title + "\n\n" + q.Desc + "\n\n"
	s += "- Card: **" + rarityName[q.Rarity] + "** (" + Season + ")\n"
	s += "- Check: " + q.Kind
	if q.Arg != "" {
		s += " `" + q.Arg + "`"
	}
	s += "\n- Pay: " + q.Pay
	if q.Pay == PayFixed {
		s += ", " + gnot(q.Reward) + " per winner"
	}
	s += "\n- Pool: " + gnot(q.Pool) + " locked of " + gnot(q.Funded) + " funded\n"
	s += "- Winners: " + itoa(len(q.Winners)) + "/" + itoa(q.Max) + "\n"
	s += "- Funder: " + short(q.Funder) + "\n- Ends: " + time.Unix(q.Expires, 0).UTC().Format("2006-01-02 15:04 UTC") + "\n"
	return s
}

func renderPassport(w address) string {
	best := BestRarity(w)
	s := "# Passport: " + short(w) + "\n\n**" + rankName[best] + "** · " +
		strconv.FormatInt(points[w], 10) + " pts · " + itoa(len(cards[w])) + " cards\n\n"
	for _, c := range cards[w] {
		s += "- " + rarityName[c.Rarity] + " · " + c.Title + " · #" + itoa(c.Serial) + " · " + c.Season + "\n"
	}
	return s
}

func renderTop() string {
	list := make([]address, len(players))
	copy(list, players)
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && points[list[j]] > points[list[j-1]]; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	s := "# Season " + Season + " leaderboard\n\n"
	for i, w := range list {
		if i == 10 {
			break
		}
		s += itoa(i+1) + ". [" + short(w) + "](:p/" + string(w) + ") · " + strconv.FormatInt(points[w], 10) + " pts\n"
	}
	return s
}
