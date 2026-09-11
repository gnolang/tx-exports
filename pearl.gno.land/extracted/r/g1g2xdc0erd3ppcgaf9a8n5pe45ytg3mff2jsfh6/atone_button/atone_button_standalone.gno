package atone_button

import (

	"strconv"
	"time"
)

// ---------- параметры игры ----------
const (
	secInitialWindow int64 = 24 * 3600 // окно в первой фазе — 24ч
	secFreePhase     int64 = 24 * 3600 // длительность фазы без кулдауна
	secMinWindow     int64 = 10 * 60   // минимальное окно — 10 минут
	secDecayPerDay   int64 = 3600      // окно сжимается на 1 час за каждые сутки после фазы
	secCooldown      int64 = 24 * 3600 // кулдаун на адрес после первой фазы

	mainPrize      int64 = 1000 // 1000 atone (внутренние условные единицы, без decimals)
	topActivePrize int64 = 100
	topHolderPrize int64 = 100

	topN = 5
)

// замените на свой g1-адрес, если захотите admin-функции (сейчас не используется,
// но пригодится, когда будете прикручивать реальный токен/сброс игры)
const admin address = "g1ВАШАДРЕСЗДЕСЬ"

type participant struct {
	addr        address
	pressCount  int64
	heldSeconds int64
	lastPress   int64
}

var (
	gameStart   int64
	lastPress   int64
	lastPresser address
	finalized   bool

	participants map[address]*participant
	balances     map[address]int64 // внутренний учёт призовых atone

	topActive [topN]*participant
	topHolder [topN]*participant
)

func init(cur realm) {
	now := time.Now().Unix()
	gameStart = now
	lastPress = now
	participants = map[address]*participant{}
	balances = map[address]int64{}
}

// ---------- внутренняя логика окна/дедлайна ----------

func currentWindow(now int64) int64 {
	if now-gameStart < secFreePhase {
		return secInitialWindow
	}
	daysIn := (now - gameStart - secFreePhase) / (24 * 3600)
	w := secInitialWindow - daysIn*secDecayPerDay
	if w < secMinWindow {
		w = secMinWindow
	}
	return w
}

func deadline() int64 {
	now := time.Now().Unix()
	return lastPress + currentWindow(now)
}

// ---------- публичные view-функции ----------

func TimeLeft() int64 {
	now := time.Now().Unix()
	d := deadline()
	if now >= d {
		return 0
	}
	return d - now
}

func CurrentLeader() address {
	return lastPresser
}

func IsFinalized() bool {
	return finalized
}


func GetPressCount(a address) int64 {
	p, ok := participants[a]
	if !ok {
		return 0
	}
	return p.pressCount
}

func GetHeldSeconds(a address) int64 {
	p, ok := participants[a]
	if !ok {
		return 0
	}
	return p.heldSeconds
}

// BalanceOf — сколько условных atone начислено адресу после Finalize()
func BalanceOf(a address) int64 {
	return balances[a]
}

func TopActiveText() string {
	s := ""
	for i := 0; i < topN; i++ {
		if topActive[i] != nil {
			s += strconv.Itoa(i+1) + ". " + string(topActive[i].addr) + " - " +
				strconv.FormatInt(topActive[i].pressCount, 10) + " nazhatiy\n"
		}
	}
	if s == "" {
		return "poka pusto"
	}
	return s
}

func TopHolderText() string {
	s := ""
	for i := 0; i < topN; i++ {
		if topHolder[i] != nil {
			s += strconv.Itoa(i+1) + ". " + string(topHolder[i].addr) + " - " +
				strconv.FormatInt(topHolder[i].heldSeconds, 10) + " sek uderzhaniya\n"
		}
	}
	if s == "" {
		return "poka pusto"
	}
	return s
}

// ---------- основное действие ----------

func Press(cur realm) {
	if finalized {
		panic("igra zavershena")
	}
	now := time.Now().Unix()
	if now >= deadline() {
		panic("vremya vyshlo - vyzovite Finalize()")
	}

	caller := cur.Previous().Address()

	if now-gameStart >= secFreePhase {
		if p, ok := participants[caller]; ok {
			if now-p.lastPress < secCooldown {
				panic("posle pervyh 24 chasov - ne chashche raza v sutki")
			}
		}
	}

	// начисляем held-время предыдущему лидеру
	if lastPresser != "" {
		if prev, ok := participants[lastPresser]; ok {
			prev.heldSeconds += now - lastPress
			upsertTop(&topHolder, prev, byHeldSeconds)
		}
	}

	p, ok := participants[caller]
	if !ok {
		p = &participant{addr: caller}
		participants[caller] = p
	}
	p.pressCount++
	p.lastPress = now
	upsertTop(&topActive, p, byPressCount)

	lastPress = now
	lastPresser = caller
}

// ---------- финализация и начисление призов ----------

func Finalize(cur realm) {
	if finalized {
		panic("uzhe finalizirovano")
	}
	now := time.Now().Unix()
	if now < deadline() {
		panic("vremya eshche ne vyshlo")
	}
	finalized = true

	if lastPresser != "" {
		if p, ok := participants[lastPresser]; ok {
			p.heldSeconds += now - lastPress
			upsertTop(&topHolder, p, byHeldSeconds)
		}
	}

	if lastPresser != "" {
		balances[lastPresser] += mainPrize
	}
	for i := 0; i < topN; i++ {
		if topActive[i] != nil {
			balances[topActive[i].addr] += topActivePrize
		}
	}
	for i := 0; i < topN; i++ {
		if topHolder[i] != nil {
			balances[topHolder[i].addr] += topHolderPrize
		}
	}
}

// ---------- helper для топ-5 ----------

func byPressCount(a, b *participant) bool  { return a.pressCount > b.pressCount }
func byHeldSeconds(a, b *participant) bool { return a.heldSeconds > b.heldSeconds }

func upsertTop(arr *[topN]*participant, p *participant, greater func(a, b *participant) bool) {
	filtered := []*participant{}
	for i := 0; i < topN; i++ {
		if arr[i] != nil && arr[i] != p {
			filtered = append(filtered, arr[i])
		}
	}
	filtered = append(filtered, p)

	for i := 1; i < len(filtered); i++ {
		j := i
		for j > 0 && greater(filtered[j], filtered[j-1]) {
			filtered[j], filtered[j-1] = filtered[j-1], filtered[j]
			j--
		}
	}

	for i := 0; i < topN; i++ {
		if i < len(filtered) {
			arr[i] = filtered[i]
		} else {
			arr[i] = nil
		}
	}
}

// ---------- Render ----------

func Render(path string) string {
	s := "# Atone Button\n\n"
	s += "Ostalos vremeni: " + strconv.FormatInt(TimeLeft(), 10) + " sek\n\n"
	s += "Tekushchiy lider: " + string(lastPresser) + "\n\n"
	s += "Finalizirovano: " + strconv.FormatBool(finalized) + "\n\n"
	s += "## Top-5 aktivnyh\n" + TopActiveText() + "\n"
	s += "## Top-5 po uderzhaniyu\n" + TopHolderText() + "\n"
	return s
}
