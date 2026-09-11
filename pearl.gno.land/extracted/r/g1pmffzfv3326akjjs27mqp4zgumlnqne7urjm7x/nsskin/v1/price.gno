package nsskin

import (
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

/*
WHAT ONE COSTS, PER DESIGN.

There used to be a single `price` for the whole collection, which is the
right shape for a launch batch and the wrong one the moment anything in
it is worth more or less than the rest — or worth nothing, which is the
interesting case.

Three sources, in order, and only the first of them stores anything:

	an ADMIN OVERRIDE, if one has been set for this id
	ZERO, if the id falls in the free share by the rule below
	the BASE PRICE otherwise

# WHY THE FREE ONES ARE COMPUTED RATHER THAN LISTED

Marking a third of sixty definitions free by storing a flag on each is
sixty writes and sixty entries that live forever, to record something
that never changes. The rule below derives it from the id, so it costs
nothing to store, nothing to keep in step, and cannot drift between the
contract, the shop and the collection file — all three ask the same
question of the same string and get the same answer.

It is ARBITRARY, which is the point: nothing about a design implies its
price, and a rule nobody can lobby is fairer than a list somebody picked.
An admin who disagrees about a particular one sets an override, and that
override is then a deliberate, visible, single stored fact.

# WHY A HASH AND NOT EVERY THIRD ONE

Definitions are iterated and displayed in id order, so "every third"
would put the free ones in a visible stripe down the grid and make the
whole thing look like a pricing table rather than a collection.
*/

/*
The threshold, out of a hundred, under which a hashed id is free.

THIRTY-FIVE, NOT THIRTY, AND THE FOUR-POINT GAP IS THE HONEST PART. The
rule is a statement about ids, not a quota, so any particular collection
lands near the threshold rather than on it — sixty ids at a threshold of
thirty came out at thirteen, which is twenty-one per cent and not the
third that was asked for. Thirty-five puts the launch batch at eighteen,
which is thirty per cent exactly.

So the constant was chosen to fit the collection that exists. That is
worth saying plainly rather than dressing up: what it buys is that every
FUTURE id still gets an answer nobody can lobby for, which is the
property that mattered, while the batch on sale today is the share that
was promised.

A constant rather than a stored value, because changing it would
silently reprice every skin nobody has overridden — including ones
people have already been shown a price for. That should cost a deploy.
*/
const freeShare = 35

// priceOverride holds ONLY the ids an admin has priced by hand. An id
// that is absent is not "free" and not "base" — it is unopinionated, and
// PriceOf decides. Storing a value for every skin would make the common
// case cost as much as the exception.
var priceOverride = avl.NewTree() // definition id -> int64 ugnot

/*
freeByRule is FNV-1a over the id, taken modulo one hundred.

freeShare of every hundred ids fall under the threshold, so the share
lands NEAR it rather than on it for any particular collection — see the
note on the constant. The launch batch of sixty comes out at eighteen,
and ListFreeSkins says so rather than asking anyone to trust the
arithmetic.

The same hash is in nsview.faceForArt, deliberately not shared: one runs
over a sprite and one over an id, they answer different questions, and a
helper spanning both realms would be a dependency between them for four
lines of arithmetic.
*/
func freeByRule(id string) bool {
	h := uint32(2166136261)
	for i := 0; i < len(id); i++ {
		h ^= uint32(id[i])
		h *= 16777619
	}
	return h%100 < freeShare
}

// IsFreeByRule reports what the rule alone says, ignoring any override.
// Exposed so an admin panel can show what it would revert to.
func IsFreeByRule(id string) bool {
	return freeByRule(strings.ToLower(strings.TrimSpace(id)))
}

// HasPriceOverride reports whether this id has been priced by hand. A
// panel needs it to tell "set to zero" from "free by the rule", which
// look identical in the price alone and are different decisions.
func HasPriceOverride(id string) bool {
	return priceOverride.Has(strings.ToLower(strings.TrimSpace(id)))
}

// PriceOf is what this design costs right now, in ugnot.
//
// It does NOT check that the id exists: a price for a definition that is
// not there is meaningless rather than wrong, and Buy is the thing that
// must refuse an unknown id — which it already does, by name, before it
// ever asks what the price is.
func PriceOf(id string) int64 {
	id = strings.ToLower(strings.TrimSpace(id))
	if v := priceOverride.Get(id); v != nil {
		return v.(int64)
	}
	if freeByRule(id) {
		return 0
	}
	return price
}

/*
SetSkinPrice prices one design by hand, overriding the rule.

Zero is a legitimate value and is NOT the same as removing the override:
it says "this one is free because I said so", which survives a change to
the base price and to the rule. ClearSkinPrice is how you go back to
being unopinionated.
*/
func SetSkinPrice(cur realm, id string, p int64) {
	assertIsAdmin(cur)
	setSkinPrice(id, p)
}

// setSkinPrice is SetSkinPrice without the realm ceremony. Split for the
// same reason attach.gno splits refresh from Refresh: the rules are
// worth testing on their own, and the gate above them is the same
// assertIsAdmin every other write in this realm goes through.
func setSkinPrice(id string, p int64) {
	id = strings.ToLower(strings.TrimSpace(id))
	if !skins.Has(id) {
		panic("nsskin: no such skin: " + id)
	}
	if p < 0 {
		panic("nsskin: a negative price is not a discount")
	}
	priceOverride.Set(id, p)
}

// ClearSkinPrice drops an override, putting the design back under the
// rule and the base price.
func ClearSkinPrice(cur realm, id string) {
	assertIsAdmin(cur)
	clearSkinPrice(id)
}

func clearSkinPrice(id string) {
	priceOverride.Remove(strings.ToLower(strings.TrimSpace(id)))
}

/*
SetSkinPrices prices many designs in one call.

A panel that lets somebody retune a collection produces a batch of
changes, and sixty separate transactions is sixty flat fees for what is
one decision. Same encoding as AllSkins reads back — tab between the id
and the price, newline between records — so the two halves of the panel
speak one format.

An empty price field CLEARS the override rather than setting zero. The
panel shows an empty box for "no opinion" and a 0 for "free on purpose",
and those must not collapse into each other on the way here.
*/
func SetSkinPrices(cur realm, packed string) {
	assertIsAdmin(cur)
	setSkinPrices(packed)
}

func setSkinPrices(packed string) {
	/* CHECKED IN FULL BEFORE ANYTHING IS WRITTEN.
	   A panic reverts the whole transaction on chain, so applying as we
	   go would come out right in production — but only because of a
	   guarantee living somewhere else. Validating first makes the
	   promise true of this function on its own, which is what the tests
	   can actually hold it to, and it costs one pass over a list that is
	   sixty lines at its largest. */
	type change struct {
		id    string
		clear bool
		p     int64
	}
	var pending []change

	for _, raw := range strings.Split(packed, "\n") {
		/* TRIMMED AROUND THE FIELDS, NOT AROUND THE LINE. Trimming the
		   whole line first ate the trailing tab of "id\t", which is the
		   form that CLEARS an override — so "no opinion" arrived here
		   looking like a line with no tab at all and was rejected as
		   malformed. Only the carriage return goes, because a form
		   posting CRLF is not making a statement about pricing. */
		line := strings.TrimRight(raw, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		tab := strings.Index(line, "\t")
		if tab < 0 {
			panic("nsskin: each line is <id>\\t<ugnot>, got: " + line)
		}
		id := strings.ToLower(strings.TrimSpace(line[:tab]))
		val := strings.TrimSpace(line[tab+1:])
		if !skins.Has(id) {
			panic("nsskin: no such skin: " + id)
		}
		if val == "" {
			pending = append(pending, change{id: id, clear: true})
			continue
		}
		p, ok := parseU64(val)
		if !ok {
			panic("nsskin: not a number of ugnot: " + val)
		}
		pending = append(pending, change{id: id, p: p})
	}

	for _, c := range pending {
		if c.clear {
			priceOverride.Remove(c.id)
			continue
		}
		priceOverride.Set(c.id, c.p)
	}
}

// parseU64 is strconv.ParseInt without the import, and without accepting
// a sign — every price here is a non-negative amount of ugnot, and "-0"
// or "+5" arriving from a form should be refused rather than guessed at.
func parseU64(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 18 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	return n, true
}

/*
ListFreeSkins names every definition that costs nothing right now,
counting overrides — so it answers "what can I have for free", which is
the question, rather than "what does the rule say", which is trivia.
*/
func ListFreeSkins() string {
	var b strings.Builder
	skins.Iterate("", "", func(k string, _ any) bool {
		if PriceOf(k) == 0 {
			b.WriteString(k + "\n")
		}
		return false
	})
	return b.String()
}

// AllPrices is every id and its price, for a shop that wants the lot in
// one read. AllSkins carries the price too; this exists for a panel that
// wants prices without the rest and for checking the two agree.
func AllPrices() string {
	var b strings.Builder
	skins.Iterate("", "", func(k string, _ any) bool {
		o := "0"
		if priceOverride.Has(k) {
			o = "1"
		}
		b.WriteString(k + "\t" + ufmt.Sprintf("%d", PriceOf(k)) + "\t" + o + "\n")
		return false
	})
	return b.String()
}
