// Package rolecall deals secret Werewolf / Mafia roles with p/hat: one
// werewolf, one seer, everyone else a villager. Each phone gets an anonymous
// slot through one shuffle round, and roles go to circle positions, so a
// player knows their own role and nobody knows anyone else's. Players call
// with their own wallets, so the caller's address is their identity.
package rolecall

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1efejv30mcyz2tglm36263ha83ttv4zfu0gnnq0/hat/v0"
)

type game struct {
	host    address
	players []address
	hat     *hat.Hat
}

var games avl.Tree // id -> *game

// New opens a game; the caller hosts it and alone can lock it.
func New(cur realm) int {
	id := games.Size() + 1
	h := hat.New(hat.Options{Rounds: 1, Step: 10 * time.Minute, JoinWindow: 24 * time.Hour}, time.Now())
	games.Set(strconv.Itoa(id), &game{host: cur.Previous().Address(), hat: h})
	return id
}

func Join(cur realm, id int, boxPub, commit string) {
	g := get(id)
	if g.seat(cur) >= 0 {
		panic("rolecall: already joined")
	}
	_, err := g.hat.Add(unhex(boxPub), unhex(commit), time.Now())
	check(err)
	g.players = append(g.players, cur.Previous().Address())
}

func Lock(cur realm, id int) {
	g := get(id)
	if cur.Previous().Address() != g.host {
		panic("rolecall: only the host can lock")
	}
	check(g.hat.Lock(-1, time.Now()))
}

func Ready(cur realm, id int, seed string) {
	g := get(id)
	var roster []byte
	for _, p := range g.players {
		roster = append(roster, []byte(p.String())...)
	}
	sum := sha256.Sum256(roster)
	check(g.hat.Ready(g.must(cur), unhex(seed), sum[:], time.Now()))
}

func Seal(cur realm, id int, onion string) {
	g := get(id)
	check(g.hat.Seal(g.must(cur), unb64(onion), time.Now()))
}

// Mix takes one shuffle turn: comma-separated base64, one layer peeled.
func Mix(cur realm, id int, items string) {
	g := get(id)
	var out [][]byte
	for _, s := range strings.Split(items, ",") {
		out = append(out, unb64(s))
	}
	check(g.hat.Mix(g.must(cur), out, time.Now()))
}

// Next returns who must shuffle now, or "" when nobody is.
func Next(id int) address {
	g := get(id)
	if e := g.hat.Expected(); e >= 0 {
		return g.players[e]
	}
	return ""
}

// Confirm says the caller's phone found its slot; when all have, roles are dealt.
func Confirm(cur realm, id int) {
	g := get(id)
	check(g.hat.Confirm(g.must(cur), time.Now()))
}

// Role is the role at circle position k. The circle order comes from the draw
// seed, so neither the host nor the last shuffler chooses who is the werewolf.
func Role(k int) string {
	switch k {
	case 0:
		return "werewolf"
	case 1:
		return "seer"
	}
	return "villager"
}

func Render(path string) string {
	id, _ := strconv.Atoi(strings.TrimPrefix(path, ":"))
	v := games.Get(strconv.Itoa(id))
	if v == nil {
		return "# Rolecall\n\nSecret Werewolf roles dealt with the Urim hat (p/hat): nobody, not even the host, knows who is who.\n"
	}
	h := v.(*game).hat
	out := "# Rolecall game " + strconv.Itoa(id) + "\n\n" + strconv.Itoa(h.Size()) + " players · " + h.Phase().String() + "\n\n"
	if h.Phase() == hat.Revealed {
		out += "Find your slot fingerprint on your phone:\n\n"
		for k, s := range h.Slots() {
			out += "- `" + hat.Fingerprint(s) + "` " + Role(k) + "\n"
		}
	}
	return out
}

func get(id int) *game {
	v := games.Get(strconv.Itoa(id))
	if v == nil {
		panic("rolecall: no such game")
	}
	return v.(*game)
}

func (g *game) seat(cur realm) int {
	for i, p := range g.players {
		if p == cur.Previous().Address() {
			return i
		}
	}
	return -1
}

func (g *game) must(cur realm) int {
	if i := g.seat(cur); i >= 0 {
		return i
	}
	panic("rolecall: not in this game")
}

func unhex(s string) []byte {
	b, err := hex.DecodeString(s)
	check(err)
	return b
}

func unb64(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	check(err)
	return b
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}
