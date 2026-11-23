// Package gnometavern is "The Gnome Tavern": a fully on-chain tavern on
// Gno.land, built for The Gnome Tavern Hackathon (DoraHacks).
//
// Gnomes (users) check in at the door, order drinks from the menu with real
// testnet ugnot, tip the keeper, and complete daily quests. Every visit,
// drink, tip and quest point lives in this realm's state — there is no
// backend and no external database. The Render function is the tavern's
// public notice board, readable by anyone through gnoweb.
//
// Payment safety: functions that accept native coins (OrderDrink, Tip)
// follow the pattern from the Gno security guide — the caller must be a
// direct EOA call (cur.Previous().IsUserCall()) and the amount is read from
// unsafe.OriginSend(). Kept together, the pair guarantees the coins checked
// are the coins that actually landed at this realm's address.
package gnometavern

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// MenuItem is one drink on the tavern menu. Price is in ugnot
// (1 GNOT = 1_000_000 ugnot). Stock counts the drinks left in the keg.
type MenuItem struct {
	Name  string
	Price int64
	Stock int64
}

// Quest is one entry on the tavern quest board. A patron can complete each
// quest at most once per day (day = unix day of chain time).
type Quest struct {
	Title  string
	Points int64
}

// Patron is the tavern's record of one gnome.
type Patron struct {
	Nickname    string
	Visits      int64
	Drinks      int64
	TipsPaid    int64 // ugnot, overpayments + explicit tips
	QuestPoints int64
}

// ---------------------------------------------------------------------------
// State (persisted by the GnoVM between transactions)
// ---------------------------------------------------------------------------

var (
	keeper address // the tavern keeper (deployer); only address that manages menu/quests

	menu   []*MenuItem
	quests []*Quest

	patrons     map[string]*Patron // key: patron address string
	patronOrder []string           // patron address strings, in first-visit order

	totalVisits int64
	totalDrinks int64
	till        int64 // total ugnot received by the tavern (drink payments + tips)

	// lastQuestClaim maps "<addr>#<questID>" to the unix day of the last claim.
	lastQuestClaim map[string]int64
)

// init runs once, when the realm is deployed. The previous realm during
// initialization is the publisher (the EOA that deployed the realm), so the
// keeper is captured from it rather than hardcoded.
func init(cur realm) {
	keeper = cur.Previous().Address()
	seed()
}

// seed (re)builds the opening menu and quest board. It is also used by the
// unit tests to reset state.
func seed() {
	menu = []*MenuItem{
		{Name: "Gnome Ale", Price: 50000, Stock: 40},
		{Name: "Mushroom Stout", Price: 80000, Stock: 30},
		{Name: "Crystal Cider", Price: 70000, Stock: 30},
		{Name: "Stardust Mead", Price: 120000, Stock: 20},
		{Name: "Dragonfire Whisky", Price: 250000, Stock: 10},
	}
	quests = []*Quest{
		{Title: "First Steps: check in at the tavern door", Points: 5},
		{Title: "Thirsty Work: order any drink from the menu", Points: 5},
		{Title: "Generous Soul: leave the keeper a tip", Points: 10},
		{Title: "Tavern Regular: come back on another day", Points: 10},
	}
	patrons = make(map[string]*Patron)
	patronOrder = nil
	totalVisits = 0
	totalDrinks = 0
	till = 0
	lastQuestClaim = make(map[string]int64)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// getOrCreatePatron returns the caller's patron record, creating an empty
// one on first interaction.
func getOrCreatePatron(addr address) *Patron {
	key := addr.String()
	if p, ok := patrons[key]; ok {
		return p
	}
	p := &Patron{}
	patrons[key] = p
	patronOrder = append(patronOrder, key)
	return p
}

// scoreOf computes a patron's Hall of Fame score:
// 1 pt per visit, 2 pts per drink, quest points as-is,
// plus 1 pt per full 0.1 GNOT (100_000 ugnot) tipped.
func scoreOf(p *Patron) int64 {
	return p.Visits + 2*p.Drinks + p.QuestPoints + p.TipsPaid/100000
}

// currentDay returns the current unix day according to chain time.
func currentDay() int64 {
	return time.Now().Unix() / 86400
}

// cleanText validates user-supplied display text (nicknames, menu and quest
// names). It rejects empty/overlong strings and characters that would break
// the markdown notice board.
func cleanText(s string, maxLen int) string {
	s = strings.TrimSpace(s)
	if s == "" {
		panic("text must not be empty")
	}
	if len(s) > maxLen {
		panic("text is too long")
	}
	if strings.ContainsAny(s, "|\n\r<>") {
		panic("text contains forbidden characters")
	}
	return s
}

// requireKeeper panics unless the caller is the tavern keeper.
func requireKeeper(cur realm) {
	if cur.Previous().Address() != keeper {
		panic("only the tavern keeper can do that")
	}
}

// requireUserPayment enforces the payment-guard pair for coin-accepting
// entry points and returns the ugnot amount attached to the transaction.
func requireUserPayment(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by a user (maketx call)")
	}
	return unsafe.OriginSend().AmountOf("ugnot")
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

// CheckIn registers the caller as a patron (first call) and records a visit.
// The nickname is set on the first check-in only; later calls keep the
// original name so nobody can rename somebody else's gnome.
func CheckIn(cur realm, nickname string) string {
	caller := cur.Previous().Address()
	key := caller.String()
	p, known := patrons[key]
	if !known {
		p = getOrCreatePatron(caller)
		p.Nickname = cleanText(nickname, 24)
	}
	p.Visits++
	totalVisits++
	return "Welcome to the Gnome Tavern, " + p.Nickname + "! Visit #" +
		strconv.FormatInt(p.Visits, 10) + "."
}

// OrderDrink serves one drink from the menu. The caller must attach at
// least the menu price in ugnot to the call (-send). Any overpayment is
// recorded as a tip to the keeper.
func OrderDrink(cur realm, itemID int64) string {
	sent := requireUserPayment(cur)
	if itemID < 0 || itemID >= int64(len(menu)) {
		panic("no such drink on the menu")
	}
	item := menu[itemID]
	if item.Stock <= 0 {
		panic("the keg is empty: " + item.Name + " is sold out")
	}
	if sent < item.Price {
		panic("not enough ugnot sent for " + item.Name)
	}
	caller := cur.Previous().Address()
	p := getOrCreatePatron(caller)

	item.Stock--
	p.Drinks++
	totalDrinks++
	till += sent
	if over := sent - item.Price; over > 0 {
		p.TipsPaid += over
	}
	return "The keeper slides a " + item.Name + " across the bar. Cheers, " +
		displayName(p, caller) + "!"
}

// Tip leaves the keeper a tip. The full amount attached to the call
// (-send, in ugnot) is recorded as a tip from the caller.
func Tip(cur realm) string {
	sent := requireUserPayment(cur)
	if sent <= 0 {
		panic("a tip must send some ugnot")
	}
	caller := cur.Previous().Address()
	p := getOrCreatePatron(caller)
	p.TipsPaid += sent
	till += sent
	return "The keeper bows. " + displayName(p, caller) + " tipped " +
		strconv.FormatInt(sent, 10) + "ugnot."
}

// CompleteQuest claims the points of one quest from the board. Each patron
// can complete a given quest at most once per day.
func CompleteQuest(cur realm, questID int64) string {
	if questID < 0 || questID >= int64(len(quests)) {
		panic("no such quest on the board")
	}
	caller := cur.Previous().Address()
	key := caller.String() + "#" + strconv.FormatInt(questID, 10)
	day := currentDay()
	if last, ok := lastQuestClaim[key]; ok && last == day {
		panic("quest already completed today — come back tomorrow")
	}
	lastQuestClaim[key] = day
	q := quests[questID]
	p := getOrCreatePatron(caller)
	p.QuestPoints += q.Points
	return "Quest complete: \"" + q.Title + "\" (+" +
		strconv.FormatInt(q.Points, 10) + " pts)."
}

// AddMenuItem puts a new drink on the menu. Keeper only.
func AddMenuItem(cur realm, name string, price int64, stock int64) string {
	requireKeeper(cur)
	if price <= 0 {
		panic("price must be positive")
	}
	if stock < 0 {
		panic("stock must not be negative")
	}
	menu = append(menu, &MenuItem{
		Name:  cleanText(name, 32),
		Price: price,
		Stock: stock,
	})
	return "Added to the menu: " + name
}

// Restock adds drinks to an existing keg. Keeper only.
func Restock(cur realm, itemID int64, amount int64) string {
	requireKeeper(cur)
	if itemID < 0 || itemID >= int64(len(menu)) {
		panic("no such drink on the menu")
	}
	if amount <= 0 {
		panic("restock amount must be positive")
	}
	menu[itemID].Stock += amount
	return "Restocked " + menu[itemID].Name + " by " +
		strconv.FormatInt(amount, 10) + "."
}

// AddQuest pins a new quest on the board. Keeper only.
func AddQuest(cur realm, title string, points int64) string {
	requireKeeper(cur)
	if points <= 0 {
		panic("quest points must be positive")
	}
	quests = append(quests, &Quest{
		Title:  cleanText(title, 64),
		Points: points,
	})
	return "New quest on the board: " + title
}

// ---------------------------------------------------------------------------
// Read-only getters (handy for judges and scripts)
// ---------------------------------------------------------------------------

// GetStats returns the tavern's headline numbers.
func GetStats() (visits int64, drinks int64, tillAmount int64, patronCount int64) {
	return totalVisits, totalDrinks, till, int64(len(patronOrder))
}

// GetPatron returns one patron's record by address.
func GetPatron(addr address) (nickname string, visits int64, drinks int64, tipsPaid int64, questPoints int64, score int64, found bool) {
	p, ok := patrons[addr.String()]
	if !ok {
		return "", 0, 0, 0, 0, 0, false
	}
	return p.Nickname, p.Visits, p.Drinks, p.TipsPaid, p.QuestPoints, scoreOf(p), true
}

// displayName returns the patron's nickname, or a short form of their
// address when they never set one.
func displayName(p *Patron, addr address) string {
	if p.Nickname != "" {
		return p.Nickname
	}
	return addr.String()
}

// ---------------------------------------------------------------------------
// Render — the tavern notice board (gnoweb)
// ---------------------------------------------------------------------------

// Render serves the realm's pages:
//
//	""               the main board: stats, menu, quest board, Hall of Fame
//	"menu"           the menu only
//	"quests"         the quest board only
//	"patron/<addr>"  one patron's card
func Render(path string) string {
	switch {
	case path == "" :
		return renderHome()
	case path == "menu":
		return renderMenu()
	case path == "quests":
		return renderQuests()
	case strings.HasPrefix(path, "patron/"):
		return renderPatron(strings.TrimPrefix(path, "patron/"))
	default:
		return "# The Gnome Tavern\n\nNo such page at the tavern. Try the [main board](/)."
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🍺 The Gnome Tavern\n\n")
	b.WriteString("An on-chain tavern on Gno.land. Check in, order a drink, tip the keeper, finish a quest — everything is recorded in this realm, no backend involved.\n\n")
	b.WriteString("**Keeper:** `" + keeper.String() + "`\n\n")
	b.WriteString("| Stat | Value |\n| --- | --- |\n")
	b.WriteString("| Total check-ins | " + strconv.FormatInt(totalVisits, 10) + " |\n")
	b.WriteString("| Drinks served | " + strconv.FormatInt(totalDrinks, 10) + " |\n")
	b.WriteString("| Registered patrons | " + strconv.Itoa(len(patronOrder)) + " |\n")
	b.WriteString("| Tavern till | " + strconv.FormatInt(till, 10) + " ugnot |\n\n")
	b.WriteString(renderMenu())
	b.WriteString("\n")
	b.WriteString(renderQuests())
	b.WriteString("\n")
	b.WriteString(renderHallOfFame())
	return b.String()
}

func renderMenu() string {
	var b strings.Builder
	b.WriteString("## 🍻 Menu\n\n")
	b.WriteString("| # | Drink | Price (ugnot) | In the keg |\n| --- | --- | --- | --- |\n")
	for i, item := range menu {
		b.WriteString("| " + strconv.Itoa(i) + " | " + item.Name + " | " +
			strconv.FormatInt(item.Price, 10) + " | " +
			strconv.FormatInt(item.Stock, 10) + " |\n")
	}
	b.WriteString("\nOrder with `OrderDrink(<id>)` and attach the price with `-send`.\n")
	return b.String()
}

func renderQuests() string {
	var b strings.Builder
	b.WriteString("## 📜 Quest board\n\n")
	b.WriteString("| # | Quest | Points |\n| --- | --- | --- |\n")
	for i, q := range quests {
		b.WriteString("| " + strconv.Itoa(i) + " | " + q.Title + " | " +
			strconv.FormatInt(q.Points, 10) + " |\n")
	}
	b.WriteString("\nEach quest can be completed once per patron per day with `CompleteQuest(<id>)`.\n")
	return b.String()
}

// renderHallOfFame lists the top 10 patrons by score.
func renderHallOfFame() string {
	var b strings.Builder
	b.WriteString("## 🏆 Hall of Fame\n\n")
	if len(patronOrder) == 0 {
		b.WriteString("No patrons yet — be the first gnome through the door (`CheckIn`).\n")
		return b.String()
	}
	// Rank patrons by score, descending (insertion sort on a copy of the
	// address list; the tavern is small and Render must stay cheap).
	ranked := make([]string, len(patronOrder))
	copy(ranked, patronOrder)
	for i := 1; i < len(ranked); i++ {
		for j := i; j > 0 && scoreOf(patrons[ranked[j]]) > scoreOf(patrons[ranked[j-1]]); j-- {
			ranked[j], ranked[j-1] = ranked[j-1], ranked[j]
		}
	}
	b.WriteString("| Rank | Patron | Visits | Drinks | Quest pts | Tips (ugnot) | Score |\n")
	b.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")
	limit := len(ranked)
	if limit > 10 {
		limit = 10
	}
	for i := 0; i < limit; i++ {
		addr := ranked[i]
		p := patrons[addr]
		b.WriteString("| " + strconv.Itoa(i+1) + " | [" + displayName(p, address(addr)) +
			"](/patron/" + addr + ") | " +
			strconv.FormatInt(p.Visits, 10) + " | " +
			strconv.FormatInt(p.Drinks, 10) + " | " +
			strconv.FormatInt(p.QuestPoints, 10) + " | " +
			strconv.FormatInt(p.TipsPaid, 10) + " | " +
			strconv.FormatInt(scoreOf(p), 10) + " |\n")
	}
	return b.String()
}

func renderPatron(addrStr string) string {
	p, ok := patrons[addrStr]
	if !ok {
		return "# Patron card\n\n`" + addrStr + "` has never visited the Gnome Tavern."
	}
	var b strings.Builder
	b.WriteString("# 🧙 Patron card\n\n")
	b.WriteString("**Name:** " + displayName(p, address(addrStr)) + "\n\n")
	b.WriteString("**Address:** `" + addrStr + "`\n\n")
	b.WriteString("| Stat | Value |\n| --- | --- |\n")
	b.WriteString("| Check-ins | " + strconv.FormatInt(p.Visits, 10) + " |\n")
	b.WriteString("| Drinks ordered | " + strconv.FormatInt(p.Drinks, 10) + " |\n")
	b.WriteString("| Quest points | " + strconv.FormatInt(p.QuestPoints, 10) + " |\n")
	b.WriteString("| Tips paid | " + strconv.FormatInt(p.TipsPaid, 10) + " ugnot |\n")
	b.WriteString("| Hall of Fame score | " + strconv.FormatInt(scoreOf(p), 10) + " |\n")
	return b.String()
}
