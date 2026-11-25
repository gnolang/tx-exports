package taletree

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
)

// keeper moderates the whole realm: it can hide passages in any tale,
// lock any tale, and pause writing. It starts as the account that
// deployed the realm.
var keeper *ownable.Ownable

func init() {
	// init runs once, inside the addpkg transaction; there is no cur
	// here, so the deployer is read from the transaction origin.
	keeper = ownable.NewWithAddress(unsafe.OriginCaller())
}

// StartTale opens a new tale with its first passage and returns the
// tale id. The caller becomes the tale's narrator.
func StartTale(cur realm, title, opening string) int {
	assertNotPaused()
	caller := cur.Previous().Address()

	title = cleanLine(title)
	checkLen(title, MinTitleLen, MaxTitleLen, ErrTitleLength)
	opening = cleanBody(opening)
	checkLen(opening, MinBodyLen, MaxBodyLen, ErrBodyLength)

	now := time.Now()
	height := runtime.ChainHeight()
	tid := taleSeq.Next()
	pid := passageSeq.Next()

	passages.Set(pid.Binary(), &Passage{
		ID:        pid,
		Tale:      tid,
		Author:    caller,
		Body:      opening,
		Height:    height,
		CreatedAt: now,
	})
	tales.Set(tid.Binary(), &Tale{
		ID:        tid,
		Title:     title,
		Narrator:  caller,
		Root:      pid,
		Passages:  1,
		Height:    height,
		CreatedAt: now,
		UpdatedAt: now,
	})

	b := bardOf(caller)
	b.Passages++
	b.Tales++
	bardPassages.Set(bardPassageKey(caller, pid), pid)

	chain.Emit("TaleStarted",
		"tale", idStr(tid),
		"passage", idStr(pid),
		"narrator", caller.String(),
	)
	return int(tid)
}

// Branch writes a new passage under parentID. choice is the link text
// readers click to reach it ("Open the cellar door"); body is the
// passage itself. Returns the new passage id.
func Branch(cur realm, parentID int, choice, body string) int {
	return write(cur.Previous().Address(), parentID, choice, body, false)
}

// WriteEnding is Branch for a passage that ends its path: nobody can
// add choices under an ending.
func WriteEnding(cur realm, parentID int, choice, body string) int {
	return write(cur.Previous().Address(), parentID, choice, body, true)
}

func write(caller address, parentID int, choice, body string, ending bool) int {
	assertNotPaused()

	parent := mustGetVisiblePassage(parentID)
	t, _ := getTale(parent.Tale)
	if t.Locked {
		panic(ErrTaleLocked)
	}
	if parent.Ending {
		panic(ErrIsEnding)
	}
	if len(parent.Children) >= MaxChoices {
		panic(ErrTooManyChoices)
	}
	depth := parent.Depth + 1
	if depth > MaxDepth || (depth == MaxDepth && !ending) {
		panic(ErrTooDeep)
	}

	choice = cleanLine(choice)
	checkLen(choice, MinChoiceLen, MaxChoiceLen, ErrChoiceLength)
	body = cleanBody(body)
	checkLen(body, MinBodyLen, MaxBodyLen, ErrBodyLength)
	for _, sid := range parent.Children {
		if s, ok := getPassage(sid); ok && !s.Hidden && sameChoice(s.Choice, choice) {
			panic(ErrDuplicateChoice)
		}
	}

	now := time.Now()
	pid := passageSeq.Next()
	passages.Set(pid.Binary(), &Passage{
		ID:        pid,
		Tale:      t.ID,
		Parent:    parent.ID,
		Author:    caller,
		Choice:    choice,
		Body:      body,
		Depth:     depth,
		Ending:    ending,
		Height:    runtime.ChainHeight(),
		CreatedAt: now,
	})
	parent.Children = append(parent.Children, pid)

	t.Passages++
	if ending {
		t.Endings++
	}
	t.UpdatedAt = now

	bardOf(caller).Passages++
	bardPassages.Set(bardPassageKey(caller, pid), pid)

	chain.Emit("PassageWritten",
		"tale", idStr(t.ID),
		"passage", idStr(pid),
		"parent", idStr(parent.ID),
		"author", caller.String(),
		"ending", strconv.FormatBool(ending),
	)
	return int(pid)
}

// Cheer adds the caller's cheer to a passage. Each address can cheer a
// passage once, and not its own. Cheers pick the canon.
func Cheer(cur realm, passageID int) {
	caller := cur.Previous().Address()
	p := mustGetVisiblePassage(passageID)
	if p.Author == caller {
		panic(ErrSelfCheer)
	}
	key := p.ID.Binary() + caller.String()
	if cheers.Has(key) {
		panic(ErrAlreadyCheered)
	}
	cheers.Set(key, true)

	p.Cheers++
	t, _ := getTale(p.Tale)
	t.Cheers++
	author := bardOf(p.Author)
	setFame(author, author.Cheers+1)

	chain.Emit("Cheered",
		"passage", idStr(p.ID),
		"by", caller.String(),
		"cheers", strconv.Itoa(p.Cheers),
	)
}

// Tip forwards the ugnot sent with this call to the author of a
// passage, in full and in the same transaction:
//
//	gnokey maketx call -func Tip -args <passageID> -send 1000000ugnot ...
//
// Only a direct call from an account is accepted, so the coins checked
// below are the coins that reached this realm.
func Tip(cur realm, passageID int) {
	// Payment guard, kept as a pair (see effective-gno, "Verifying
	// inbound Coin payments"): IsUserCall ensures no realm or `maketx run`
	// script sat between the signer and this function, so OriginSend
	// is what this realm received.
	if !cur.Previous().IsUserCall() {
		panic(ErrTipCaller)
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 || len(sent) != 1 {
		panic(ErrTipAmount)
	}

	caller := cur.Previous().Address()
	p := mustGetVisiblePassage(passageID)
	if p.Author == caller {
		panic(ErrSelfTip)
	}

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), p.Author, chain.NewCoins(chain.NewCoin("ugnot", amount)))

	p.Tips += amount
	bardOf(p.Author).Tips += amount
	totalTips += amount

	chain.Emit("Tipped",
		"passage", idStr(p.ID),
		"from", caller.String(),
		"to", p.Author.String(),
		"ugnot", strconv.FormatInt(amount, 10),
	)
}

// Hide takes a passage, and everything under it, off the pages. The
// text stays in state, so Unhide can bring it back. Allowed for the
// tale's narrator and the keeper.
func Hide(cur realm, passageID int, reason string) {
	caller := cur.Previous().Address()
	p := mustGetPassage(passageID)
	t, _ := getTale(p.Tale)
	assertModerator(caller, t)
	if p.Hidden {
		panic(ErrAlreadyHidden)
	}
	reason = cleanLine(reason)
	checkLen(reason, 0, MaxReasonLen, ErrReasonLength)

	p.Hidden = true
	p.HiddenReason = reason
	chain.Emit("PassageHidden", "passage", idStr(p.ID), "by", caller.String(), "reason", reason)
}

// Unhide reverses Hide.
func Unhide(cur realm, passageID int) {
	caller := cur.Previous().Address()
	p := mustGetPassage(passageID)
	t, _ := getTale(p.Tale)
	assertModerator(caller, t)
	if !p.Hidden {
		panic(ErrNotHidden)
	}
	p.Hidden = false
	p.HiddenReason = ""
	chain.Emit("PassageUnhidden", "passage", idStr(p.ID), "by", caller.String())
}

// LockTale closes a tale to new passages. Cheers and tips still work.
func LockTale(cur realm, taleID int) {
	caller := cur.Previous().Address()
	t := mustGetTale(taleID)
	assertModerator(caller, t)
	t.Locked = true
	chain.Emit("TaleLocked", "tale", idStr(t.ID), "by", caller.String())
}

// UnlockTale reopens a locked tale.
func UnlockTale(cur realm, taleID int) {
	caller := cur.Previous().Address()
	t := mustGetTale(taleID)
	assertModerator(caller, t)
	t.Locked = false
	chain.Emit("TaleUnlocked", "tale", idStr(t.ID), "by", caller.String())
}

// SetPaused stops (or resumes) all writing in the realm. Keeper only.
func SetPaused(cur realm, value bool) {
	keeper.AssertOwnedBy(cur.Previous().Address())
	paused = value
	chain.Emit("PauseChanged", "paused", strconv.FormatBool(value))
}

// TransferKeeper hands the keeper role to another address. Keeper only.
func TransferKeeper(cur realm, newKeeper address) {
	if err := keeper.TransferOwnership(0, cur, newKeeper); err != nil {
		panic(err)
	}
}

// Keeper returns the address of the realm keeper.
func Keeper() address {
	return keeper.Owner()
}

func assertNotPaused() {
	if paused {
		panic(ErrPaused)
	}
}

func assertModerator(caller address, t *Tale) {
	if caller != t.Narrator && !keeper.OwnedBy(caller) {
		panic(ErrUnauthorized)
	}
}

func idStr(id seqid.ID) string {
	return strconv.FormatUint(uint64(id), 10)
}
