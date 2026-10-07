package connect4_v3

import (
	"strconv"
	"strings"
	"time"
)

// GameJSON returns {"now":<unix>,"game":<game>|null}. It is a read-only
// accessor for clients querying over vm/qeval; now is the block time.
func GameJSON(id int) string {
	var b strings.Builder
	writeNow(&b)
	b.WriteString(`,"game":`)
	if g := get(id); g != nil {
		writeGame(&b, g)
	} else {
		b.WriteString("null")
	}
	b.WriteString("}")
	return b.String()
}

// ActiveJSON returns {"now":<unix>,"games":[...]}: Open and Playing games in
// id order, skipping offset and returning at most limit (clamped to 1-100).
func ActiveJSON(offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit < 1 {
		limit = 1
	}
	if limit > 100 {
		limit = 100
	}
	var b strings.Builder
	writeNow(&b)
	b.WriteString(`,"games":[`)
	n := 0
	active.IterateByOffset(offset, limit, func(_ string, v any) bool {
		if n > 0 {
			b.WriteString(",")
		}
		writeGame(&b, v.(*Game))
		n++
		return false
	})
	b.WriteString("]}")
	return b.String()
}

func writeNow(b *strings.Builder) {
	b.WriteString(`{"now":`)
	b.WriteString(strconv.FormatInt(time.Now().Unix(), 10))
}

// writeGame emits one game. Every stored string is validated on write
// (addresses by IsValid, the commitment as hex), so Quote is defence in depth.
func writeGame(b *strings.Builder, g *Game) {
	turnPlayer := ""
	deadline := int64(0)
	if g.Status == Playing {
		deadline = g.deadline().Unix()
		if g.Turn != 0 {
			turnPlayer = g.player(g.Turn).String()
		}
	}
	b.WriteString(`{"id":`)
	b.WriteString(strconv.Itoa(g.ID))
	writeStr(b, "creator", g.Creator.String())
	writeStr(b, "opponent", g.Opponent.String())
	writeStr(b, "acceptor", g.Acceptor.String())
	writeNum(b, "stake", g.Stake)
	writeNum(b, "fee", g.Fee)
	writeNum(b, "expiresAt", g.ExpiresAt.Unix())
	writeStr(b, "commitment", g.Commitment)
	b.WriteString(`,"board":"`)
	for c := 0; c < cols; c++ {
		for r := 0; r < rows; r++ {
			b.WriteByte('0' + g.Board[c][r])
		}
	}
	b.WriteString(`"`)
	writeNum(b, "turn", int64(g.Turn))
	writeStr(b, "turnPlayer", turnPlayer)
	writeNum(b, "moves", int64(g.Moves))
	writeNum(b, "lastCol", int64(g.LastCol))
	writeNum(b, "lastRow", int64(g.LastRow))
	writeNum(b, "deadline", deadline)
	writeStr(b, "status", g.Status.String())
	writeStr(b, "winner", g.Winner.String())
	b.WriteString("}")
}

// writeStr and writeNum append `,"k":v`; the caller writes the first field.
func writeStr(b *strings.Builder, k, v string) {
	b.WriteString(`,"`)
	b.WriteString(k)
	b.WriteString(`":`)
	b.WriteString(strconv.Quote(v))
}

func writeNum(b *strings.Builder, k string, v int64) {
	b.WriteString(`,"`)
	b.WriteString(k)
	b.WriteString(`":`)
	b.WriteString(strconv.FormatInt(v, 10))
}
