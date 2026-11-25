package coppermug

import (
	"strings"

	"chain/runtime"
)

// joinErr reports why a wallet cannot take a stool, or "" if it can.
func joinErr(addr, name, class string) string {
	if _, taken := seats[addr]; taken {
		return "you already have a stool here"
	}
	if msg := nameErr(name); msg != "" {
		return msg
	}
	if _, used := byName[strings.ToLower(strings.TrimSpace(name))]; used {
		return "that name is already behind the bar"
	}
	if _, ok := classFromString(class); !ok {
		return "unknown class: pick fighter, rogue, mage or bard"
	}
	return ""
}

// Join claims a stool. One seat per wallet, one wallet per name.
func Join(cur realm, name string, class string) {
	addr, _ := caller(cur)
	if msg := joinErr(addr, name, class); msg != "" {
		panic(msg)
	}

	n := strings.TrimSpace(name)
	c, _ := classFromString(class)
	h := runtime.ChainHeight()
	a := &Adventurer{
		Name:     n,
		Class:    c,
		Gold:     StartingGold,
		Joined:   h,
		LastSeen: h,
	}
	seats[addr] = a
	byName[strings.ToLower(n)] = addr
	touch(addr)

	addPost("join", addr, a, "*"+n+"* the "+c.Label()+" pulls up a stool.")
	emit("Join", "addr", addr, "name", n, "class", c.Label())
}

// sayErr reports whether a seated adventurer may speak at this height.
func sayErr(addr string, height int64) string {
	a, ok := seats[addr]
	if !ok {
		return "no stool yet: call Join first"
	}
	if a.LastPost != 0 && height-a.LastPost < SayCooldown {
		return "easy there: one tale every few blocks"
	}
	return ""
}

// Say adds a line to the common-room board.
func Say(cur realm, text string) {
	addr, _ := caller(cur)
	h := runtime.ChainHeight()
	if msg := sayErr(addr, h); msg != "" {
		panic(msg)
	}
	msg, errMsg := cleanText(text)
	if errMsg != "" {
		panic(errMsg)
	}

	a := seats[addr]
	a.LastPost = h
	a.LastSeen = h

	addPost("say", addr, a, msg)
	emit("Say", "addr", addr, "id", itoa(nextPostID))
}

// tipCheck resolves a tip, returning the recipient address or a message.
func tipCheck(addr, to string, amount int64) (string, string) {
	a, ok := seats[addr]
	if !ok {
		return "", "no stool yet: call Join first"
	}
	if amount <= 0 {
		return "", "a tip has to be worth something"
	}
	if amount > a.Gold {
		return "", "you cannot tip gold you do not have"
	}
	recipient, ok := byName[strings.ToLower(strings.TrimSpace(to))]
	if !ok {
		return "", "nobody by that name is sitting here"
	}
	if recipient == addr {
		return "", "you cannot tip yourself; the house is watching"
	}
	return recipient, ""
}

// Tip passes gold to another adventurer and earns them a little renown.
func Tip(cur realm, to string, amount int64) int64 {
	addr, _ := caller(cur)
	h := runtime.ChainHeight()

	recipient, msg := tipCheck(addr, to, amount)
	if msg != "" {
		panic(msg)
	}

	a := seats[addr]
	b := seats[recipient]
	a.Gold -= amount
	b.Gold += amount
	if rep := amount / 10; rep > 0 {
		b.Rep += rep
	}
	a.LastSeen = h
	b.LastSeen = h
	touch(addr)
	touch(recipient)

	addPost("tip", addr, a, "slides **"+itoa(amount)+" gold** across the table to *"+b.Name+"*.")
	emit("Tip", "from", addr, "to", recipient, "amount", itoa(amount))
	return a.Gold
}

// cheerCheck finds a post a seated adventurer may cheer, or says why not.
func cheerCheck(addr string, postID int64) (*Post, string) {
	if _, ok := seats[addr]; !ok {
		return nil, "no stool yet: call Join first"
	}

	var target *Post
	for i := len(feed) - 1; i >= 0; i-- {
		if feed[i].ID == postID {
			target = feed[i]
			break
		}
	}
	if target == nil {
		return nil, "that tale has already left the board"
	}
	if target.Author == addr {
		return nil, "you cannot cheer your own tale"
	}
	for _, c := range target.Cheers {
		if c == addr {
			return nil, "you already cheered that one"
		}
	}
	return target, ""
}

// Cheer raises a glass to somebody else's tale. One cheer per wallet per post.
func Cheer(cur realm, postID int64) {
	addr, _ := caller(cur)
	target, msg := cheerCheck(addr, postID)
	if msg != "" {
		panic(msg)
	}

	target.Cheers = append(target.Cheers, addr)
	if author, ok := seats[target.Author]; ok {
		author.Rep++
	}
	a := seats[addr]
	a.LastSeen = runtime.ChainHeight()
	touch(addr)
	emit("Cheer", "addr", addr, "post", itoa(postID))
}

// roundErr reports whether a seated adventurer can buy the room a round.
func roundErr(addr string) string {
	a, ok := seats[addr]
	if !ok {
		return "no stool yet: call Join first"
	}
	if a.Gold < RoundCost {
		return "a round costs 25 gold and you are short"
	}
	return ""
}

// BuyRound spends gold on the room: up to ten recently active neighbours
// each get a small share, and the buyer earns a point of renown.
func BuyRound(cur realm) (int, int64) {
	addr, _ := caller(cur)
	if msg := roundErr(addr); msg != "" {
		panic(msg)
	}

	a := seats[addr]
	a.Gold -= RoundCost
	served := 0
	for i := len(recent) - 1; i >= 0 && served < MaxRoundShare; i-- {
		other := recent[i]
		if other == addr {
			continue
		}
		if b, ok := seats[other]; ok {
			b.Gold += RoundShare
			served++
		}
	}
	a.Rep++
	a.LastSeen = runtime.ChainHeight()
	touch(addr)

	text := "buys the room a round — " + itoa(int64(served)) + " neighbour(s) raise a glass."
	addPost("round", addr, a, text)
	emit("Round", "addr", addr, "served", itoa(int64(served)))
	return served, a.Gold
}
