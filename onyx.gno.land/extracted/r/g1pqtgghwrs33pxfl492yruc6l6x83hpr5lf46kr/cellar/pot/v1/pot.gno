// Package pot pays out GNOT the way a Cellar sheet says.
//
// A pot is an address of its own, tied to two areas of a sheet: who gets paid,
// and how large their shares are. Anyone can send GNOT to the address. Once the
// "ready" cell of the sheet is TRUE, anyone can call Settle, and the money is
// divided in proportion to the shares.
//
// The three areas must be locked when the pot is opened, so the rule cannot be
// changed while money is in it. The cells the formulas read may still change:
// that is how judges score. See the rules page of the sheet for who may write
// them.
//
// If the sheet is still not ready when the deadline passes, Refund returns the
// money to whoever opened the pot.
package pot

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math/bits"
	"strconv"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/v1"
)

const maxPayees = 20

type pot struct {
	opener   address
	sheet    string
	payees   string // area of addresses
	shares   string // area of numbers
	ready    string // cell that must be TRUE
	deadline int64  // height after which Refund is possible
	paid     int64  // ugnot paid out so far, refunds included
}

var (
	pots = avl.NewTree() // number, as text -> *pot
	path = unsafe.CurrentRealm().PkgPath()
)

// Open makes a pot and returns its number. payees and shares are areas of one
// row or one column with the same number of cells. All three areas must be
// locked already.
func Open(cur realm, sheet, payees, shares, ready string, deadline int64) int {
	p, ok := formula.ParseArea(payees)
	s, ok2 := formula.ParseArea(shares)
	if !ok || !ok2 || !isLine(p) || !isLine(s) || p.Size() != s.Size() || p.Size() > maxPayees {
		panic("pot: payees and shares are lines of the same length, at most 20 cells")
	}
	if _, _, ok := formula.ParseCell(ready); !ok {
		panic("pot: ready is one cell")
	}
	for _, area := range []string{payees, shares, ready} {
		if !cellar.IsLocked(sheet, area) {
			panic("pot: " + area + " must be locked first")
		}
	}
	if deadline <= runtime.ChainHeight() {
		panic("pot: the deadline must be a block in the future")
	}
	opener := cur.Previous().Address()
	number := pots.Size() + 1
	pots.Set(strconv.Itoa(number), &pot{opener, sheet, payees, shares, ready, deadline, 0})
	chain.Emit("PotOpened",
		"pot", strconv.Itoa(number),
		"sheet", sheet,
		"address", Address(number).String(),
	)
	return number
}

// Settle divides the money in a pot among the payees. Anyone can call it, once
// the sheet is ready. Money that cannot be divided evenly, less than one ugnot
// per payee, stays in the pot.
func Settle(cur realm, number int) {
	p := mustPot(number)
	sub := cur.Sub(subpath(number))
	total := balance(number)
	plan, problem := p.plan(total)
	if problem != "" {
		panic("pot: " + problem)
	}
	sum := int64(0)
	for _, x := range plan {
		sum += x.amount
	}
	if sum == 0 {
		panic("pot: there is nothing to pay out")
	}
	p.paid += sum
	b := banker.NewBanker(banker.BankerTypeRealmSend, sub)
	for _, x := range plan {
		if x.amount > 0 {
			b.SendCoins(sub.Address(), x.to, chain.NewCoins(chain.NewCoin("ugnot", x.amount)))
		}
	}
	chain.Emit("PotSettled", "pot", strconv.Itoa(number), "ugnot", strconv.FormatInt(sum, 10))
}

// Refund returns the money in a pot to its opener. Anyone can call it, but only
// after the deadline and only while Settle is not possible.
func Refund(cur realm, number int) {
	p := mustPot(number)
	if runtime.ChainHeight() <= p.deadline {
		panic("pot: the deadline has not passed")
	}
	total := balance(number)
	if _, problem := p.plan(total); problem == "" {
		panic("pot: the sheet is ready, so settle instead")
	}
	if total == 0 {
		panic("pot: there is nothing to refund")
	}
	p.paid += total
	sub := cur.Sub(subpath(number))
	b := banker.NewBanker(banker.BankerTypeRealmSend, sub)
	b.SendCoins(sub.Address(), p.opener, chain.NewCoins(chain.NewCoin("ugnot", total)))
	chain.Emit("PotRefunded", "pot", strconv.Itoa(number), "ugnot", strconv.FormatInt(total, 10))
}

// Address returns the address that holds the money of a pot.
func Address(number int) address {
	mustPot(number)
	return chain.DerivePkgSubAddr(path, subpath(number))
}

// Balance returns the ugnot in a pot.
func Balance(number int) int64 { return balance(number) }

func balance(number int) int64 {
	return banker.NewReadonlyBanker().GetCoin(Address(number), "ugnot")
}

func subpath(number int) string { return "pot/" + strconv.Itoa(number) }

func mustPot(number int) *pot {
	p := pots.Get(strconv.Itoa(number))
	if p == nil {
		panic("pot: no such pot")
	}
	return p.(*pot)
}

type payment struct {
	to     address
	share  formula.Num
	amount int64
}

// plan returns what each payee would get of total, or what is in the way.
func (p *pot) plan(total int64) ([]payment, string) {
	ready := cellar.Value(p.sheet, p.ready)
	if ready.Kind() != formula.Bool || ready.String() != "TRUE" {
		return nil, p.ready + " is not TRUE yet"
	}
	who := cellar.Values(p.sheet, p.payees)
	how := cellar.Values(p.sheet, p.shares)
	out := make([]payment, 0, len(who))
	sum := formula.Num(0)
	for i, v := range how {
		share, ok := v.Num()
		if !ok || share < 0 {
			return nil, "share " + strconv.Itoa(i+1) + " is not a positive number or zero"
		}
		if sum, ok = formula.Add(sum, share); !ok {
			return nil, "the shares are too large"
		}
		to := address(who[i].String())
		if share > 0 && !to.IsValid() {
			return nil, "payee " + strconv.Itoa(i+1) + " is not an address"
		}
		out = append(out, payment{to: to, share: share})
	}
	if sum == 0 {
		return nil, "all shares are zero"
	}
	for i := range out {
		// total*share/sum, rounded down; it fits because share <= sum.
		hi, lo := bits.Mul64(uint64(total), uint64(out[i].share))
		q, _ := bits.Div64(hi, lo, uint64(sum))
		out[i].amount = int64(q)
	}
	return out, ""
}

func isLine(a formula.Range) bool { return a.Cols() == 1 || a.Rows() == 1 }
