package crazy_battle

import "strconv"

type Fighter struct {
	Name   string
	HP     int
	Attack int
	Wins   int
	Losses int
}

var fighters map[string]*Fighter

func init() {
	fighters = make(map[string]*Fighter)
}

func Register(_ realm, name string, hp, attack int) {
	fighters[name] = &Fighter{Name: name, HP: hp, Attack: attack}
}

func Battle(_ realm, f1, f2 string) string {
	a := fighters[f1]
	b := fighters[f2]
	if a == nil || b == nil {
		panic("fighter not found")
	}
	for a.HP > 0 && b.HP > 0 {
		b.HP -= a.Attack
		if b.HP <= 0 {
			a.Wins++
			b.Losses++
			return f1
		}
		a.HP -= b.Attack
		if a.HP <= 0 {
			b.Wins++
			a.Losses++
			return f2
		}
	}
	return "draw"
}

func Render(_ string) string {
	out := "CRAZY BATTLE ARENA - " + strconv.Itoa(len(fighters)) + " fighters\n"
	for _, f := range fighters {
		out += "  " + f.Name + " W=" + strconv.Itoa(f.Wins) + " L=" + strconv.Itoa(f.Losses) + "\n"
	}
	return out
}
