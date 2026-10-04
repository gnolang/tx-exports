package shots

import (
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/shootout/v0"
)

// ---------------------------------------------------------------- JSON

func q(s string) string { return strconv.Quote(s) }

func kv(k, v string) string { return q(k) + ":" + v }

func obj(fields ...string) string { return "{" + strings.Join(fields, ",") + "}" }

func gameJSON(g shootout.Game) string {
	return obj(
		kv("id", strconv.FormatUint(g.ID, 10)),
		kv("creator", q(string(g.Creator))),
		kv("status", q(g.Status.String())),
		kv("pot", itoa(g.Pot)),
		kv("entryFee", itoa(g.EntryFee)),
		kv("timeoutBlocks", itoa(g.TimeoutBlocks)),
		kv("config", q(g.Config.String())),
		kv("sessions", strconv.Itoa(g.Sessions)),
		kv("winner", q(string(g.Winner))),
		kv("createdHeight", itoa(g.CreatedHeight)),
		kv("closedHeight", itoa(g.ClosedHeight)),
	)
}

func resultJSON(r penalty.Result) string {
	return obj(
		kv("outcome", q(r.Outcome.String())),
		kv("x", itoa(r.X)),
		kv("y", itoa(r.Y)),
		kv("arrivalMs", itoa(r.ArrivalMS)),
		kv("ballSpeed", itoa(r.BallSpeed)),
		kv("mishitX", itoa(r.MishitX)),
		kv("mishitY", itoa(r.MishitY)),
		kv("keeper", q(r.Keeper.String())),
	)
}

func shotJSON(s penalty.ShotInput) string {
	return obj(kv("aimX", itoa(s.AimX)), kv("aimY", itoa(s.AimY)), kv("contactX", itoa(s.ContactX)),
		kv("contactY", itoa(s.ContactY)), kv("power", itoa(s.Power)))
}

func planJSON(p penalty.KeeperPlan) string {
	return obj(kv("direction", strconv.Itoa(int(p.Direction))), kv("speed", strconv.Itoa(int(p.Speed))),
		kv("jump", strconv.Itoa(int(p.Jump))), kv("reaction", strconv.Itoa(int(p.Reaction))))
}

func kickJSON(k shootout.Kick) string {
	return obj(
		kv("round", strconv.Itoa(k.Round)),
		kv("kicker", q(k.Kicker.String())),
		kv("shot", shotJSON(k.Shot.Input())),
		kv("mishit", q(penalty.MishitHex(k.Shot.Mishit))),
		kv("plan", planJSON(k.Plan)),
		kv("seed", q(k.Seed.Hex())),
		kv("result", resultJSON(k.Result)),
		kv("height", itoa(k.Height)),
		kv("time", itoa(k.Time)),
	)
}

func sessionJSON(s shootout.Session) string {
	kicks := make([]string, len(s.Kicks))
	for i, k := range s.Kicks {
		kicks[i] = kickJSON(k)
	}
	sc := s.Score
	return obj(
		kv("gameId", strconv.FormatUint(s.GameID, 10)),
		kv("no", strconv.Itoa(s.No)),
		kv("player", q(string(s.Player))),
		kv("status", q(s.Status.String())),
		kv("paid", itoa(s.Paid)),
		kv("score", obj(kv("playerKicks", strconv.Itoa(sc.PlayerKicks)), kv("playerGoals", strconv.Itoa(sc.PlayerGoals)),
			kv("chainKicks", strconv.Itoa(sc.ChainKicks)), kv("chainGoals", strconv.Itoa(sc.ChainGoals)))),
		kv("next", q(s.Next())),
		kv("kicks", "["+strings.Join(kicks, ",")+"]"),
		kv("joinHeight", itoa(s.JoinHeight)),
		kv("lastActionHeight", itoa(s.LastActionHeight)),
		kv("endHeight", itoa(s.EndHeight)),
	)
}

// ---------------------------------------------------------------- Render

// Render shows the games list, one game ("game/<id>") or one shootout
// ("game/<id>/<session>").
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) >= 2 && parts[0] == "game" {
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return "# Not found\n"
		}
		if len(parts) >= 3 {
			no, err := strconv.Atoi(parts[2])
			if err != nil {
				return "# Not found\n"
			}
			return renderSession(id, no)
		}
		return renderGame(id)
	}
	return renderHome()
}

func ugnot(n int64) string {
	whole := n / 1000000
	frac := n % 1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := strconv.FormatInt(frac+1000000, 10)[1:]
	return itoa(whole) + "." + strings.TrimRight(f, "0") + " GNOT"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Spot Kick\n\nA pay-to-play penalty shootout against the chain. ")
	b.WriteString("Join an open game by paying its entry fee, then take five kicks and keep five. ")
	b.WriteString("Beat the chain and the pot is yours.\n\n")
	b.WriteString("| Game | Status | Pot | Entry | Challengers |\n|---|---|---:|---:|---:|\n")
	n := 0
	games.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*shootout.Game)
		id := strconv.FormatUint(g.ID, 10)
		b.WriteString("| [#" + id + "](:game/" + id + ") | " + g.Status.String() + " | " + ugnot(g.Pot) +
			" | " + ugnot(g.EntryFee) + " | " + strconv.Itoa(g.Sessions) + " |\n")
		n++
		return n >= 50
	})
	if n == 0 {
		b.WriteString("| _no games yet_ | | | | |\n")
	}
	b.WriteString("\nRules engine: ")
	if p := proxy.LivePath(); p != "" {
		b.WriteString("`" + p + "` — " + live().Describe() + "\n")
	} else {
		b.WriteString("_none accepted yet_\n")
	}
	return b.String()
}

func renderGame(id uint64) string {
	g, ok := getGame(id)
	if !ok {
		return "# Game not found\n"
	}
	sid := strconv.FormatUint(id, 10)
	var b strings.Builder
	b.WriteString("# Game #" + sid + "\n\n")
	b.WriteString("**" + g.Status.String() + "** · pot **" + ugnot(g.Pot) + "** · entry " + ugnot(g.EntryFee) +
		" · timeout " + itoa(g.TimeoutBlocks) + " blocks\n\n")
	b.WriteString("Created by `" + string(g.Creator) + "` at height " + itoa(g.CreatedHeight) + ".\n\n")
	if g.Status == shootout.GameWon {
		b.WriteString("Won by `" + string(g.Winner) + "` at height " + itoa(g.ClosedHeight) + ".\n\n")
	}
	b.WriteString("Constants: `" + g.Config.String() + "`\n\n")
	if g.Sessions > 0 {
		b.WriteString("## Challengers\n\n| # | Player | Status | Score |\n|---|---|---|---|\n")
		for no := g.Sessions; no >= 1 && no > g.Sessions-50; no-- {
			s, ok := getSession(id, no)
			if !ok {
				continue
			}
			sn := strconv.Itoa(no)
			b.WriteString("| [" + sn + "](:game/" + sid + "/" + sn + ") | `" + string(s.Player) + "` | " +
				s.Status.String() + " | " + score(s.Score) + " |\n")
		}
	}
	return b.String()
}

func score(s penalty.Shootout) string {
	return strconv.Itoa(s.PlayerGoals) + "/" + strconv.Itoa(s.PlayerKicks) + " – " +
		strconv.Itoa(s.ChainGoals) + "/" + strconv.Itoa(s.ChainKicks)
}

func renderSession(id uint64, no int) string {
	s, ok := getSession(id, no)
	if !ok {
		return "# Shootout not found\n"
	}
	var b strings.Builder
	b.WriteString("# Game #" + strconv.FormatUint(id, 10) + " · challenger " + strconv.Itoa(no) + "\n\n")
	b.WriteString("`" + string(s.Player) + "` · **" + s.Status.String() + "** · player " + score(s.Score) +
		" chain · next: " + s.Next() + "\n\n")
	b.WriteString("| Round | Kicker | Shot | Keeper plan | Outcome | At (mm) |\n|---|---|---|---|---|---|\n")
	for _, k := range s.Kicks {
		b.WriteString("| " + strconv.Itoa(k.Round) + " | " + k.Kicker.String() + " | " + k.Shot.Input().String() +
			" | " + k.Plan.String() + " (" + k.Result.Keeper.String() + ") | **" + k.Result.Outcome.String() +
			"** | " + itoa(k.Result.X) + ", " + itoa(k.Result.Y) + " |\n")
	}
	return b.String()
}
