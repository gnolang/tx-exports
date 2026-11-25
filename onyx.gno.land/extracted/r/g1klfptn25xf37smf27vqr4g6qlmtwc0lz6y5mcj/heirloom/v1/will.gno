package heirloom

import (
	"math/bits"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	MaxHeirs        = 10
	MaxAssets       = 10
	MinSilence      = day
	MaxSilence      = 3650 * day
	ObjectionPeriod = 7 * day

	day = 24 * time.Hour
)

type willStatus string

const (
	statusActive    willStatus = "active"
	statusDue       willStatus = "due"
	statusRequested willStatus = "requested"
	statusReleased  willStatus = "released"
)

type Heir struct {
	Addr    address
	Percent int

	claimed avl.Tree
}

type Will struct {
	ID          int
	Owner       address
	Heirs       []*Heir
	Successor   address
	Silence     time.Duration
	LastSeen    time.Time
	RequestedAt time.Time
	RequestedBy address
	ReleasedAt  time.Time

	held   avl.Tree
	hidden avl.Tree
}

func (w *Will) releaseAt() time.Time {
	return w.LastSeen.Add(w.Silence)
}

func (w *Will) isReleased() bool {
	return !w.ReleasedAt.IsZero()
}

func (w *Will) isDue() bool {
	return !w.isReleased() && !time.Now().Before(w.releaseAt())
}

func (w *Will) isRequested() bool {
	return !w.isReleased() && !w.RequestedAt.IsZero()
}

func (w *Will) objectionEnds() time.Time {
	return w.RequestedAt.Add(ObjectionPeriod)
}

func (w *Will) status() willStatus {
	switch {
	case w.isReleased():
		return statusReleased
	case w.isRequested():
		return statusRequested
	case w.isDue():
		return statusDue
	}
	return statusActive
}

func (w *Will) touch() {
	w.LastSeen = time.Now()
	if w.isRequested() {
		w.RequestedAt, w.RequestedBy = time.Time{}, ""
		emit("ReleaseCancelled", w)
	}
}

func (w *Will) heir(addr address) *Heir {
	for _, h := range w.Heirs {
		if h.Addr == addr {
			return h
		}
	}
	return nil
}

func (w *Will) names(addr address) bool {
	return w.heir(addr) != nil || w.Successor == addr
}

func (w *Will) hiddenFor(addr address) bool {
	return w.hidden.Has(addr.String())
}

func (w *Will) balance(asset string) int64 {
	amount, _ := w.held.Get(asset).(int64)
	return amount
}

func (w *Will) assets() []string {
	return keys(&w.held)
}

func (w *Will) add(asset string, amount int64) {
	if !w.held.Has(asset) && w.held.Size() >= MaxAssets {
		panic(ufmt.Sprintf("a will can hold at most %d different assets", MaxAssets))
	}
	total := w.balance(asset) + amount
	if total < w.balance(asset) {
		panic("the will cannot hold that much of " + asset)
	}
	w.held.Set(asset, total)
}

func (w *Will) take(asset string, amount int64) {
	left := w.balance(asset) - amount
	switch {
	case left < 0:
		panic("the will does not hold that much of " + asset)
	case left == 0:
		w.held.Remove(asset)
	default:
		w.held.Set(asset, left)
	}
}

func (w *Will) release() {
	w.ReleasedAt = time.Now()
}

func (w *Will) shareOf(h *Heir, asset string) int64 {
	total := w.balance(asset)
	if h != w.Heirs[0] {
		return mulDiv(total, int64(h.Percent), 100)
	}
	rest := total
	for _, other := range w.Heirs[1:] {
		rest -= mulDiv(total, int64(other.Percent), 100)
	}
	return rest
}

func (h *Heir) hasClaimed(asset string) bool {
	return h.claimed.Has(asset)
}

func keys(t *avl.Tree) []string {
	var ks []string
	t.Iterate("", "", func(k string, _ any) bool {
		ks = append(ks, k)
		return false
	})
	return ks
}

func mulDiv(a, b, c int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	quo, _ := bits.Div64(hi, lo, uint64(c))
	return int64(quo)
}
