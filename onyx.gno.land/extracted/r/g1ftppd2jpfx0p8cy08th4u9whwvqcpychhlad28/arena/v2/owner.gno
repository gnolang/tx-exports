package arena

import (
	"strconv"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
)

// Owner tools. A bot's owner is the account that sent the transaction which
// registered it. Only the owner can describe, retire or upgrade a bot.

const maxDescription = 200

func mustOwn(cur realm, name string) *Bot {
	b := mustBot(name)
	if cur.Previous().Address() != b.Owner {
		panic("only the owner of " + name + " can do this")
	}
	return b
}

// cleanText keeps a description on one line and drops characters that would
// turn it into markdown links, images, tables or HTML on the bot's page.
func cleanText(s string) string {
	var sb strings.Builder
	for _, c := range s {
		switch {
		case c == '\n' || c == '\r' || c == '\t':
			sb.WriteRune(' ')
		case strings.ContainsRune("<>[]()|*_`#!\\", c):
			// dropped
		default:
			sb.WriteRune(c)
		}
	}
	out := strings.TrimSpace(sb.String())
	if len(out) > maxDescription {
		out = out[:maxDescription]
	}
	return out
}

// SetDescription sets the one-line description shown on the bot's page.
func SetDescription(cur realm, name, text string) {
	b := mustOwn(cur, name)
	b.Description = cleanText(text)
	emit("BotDescribed", "name", name)
}

// Retire takes a bot off the leaderboard and stops new challenges against
// it. Its history stays. Matches already created can still be finished.
func Retire(cur realm, name string) {
	b := mustOwn(cur, name)
	if b.Retired {
		panic(name + " is already retired")
	}
	b.Retired = true
	emit("BotRetired", "name", name)
}

// Unretire brings a retired bot back.
func Unretire(cur realm, name string) {
	b := mustOwn(cur, name)
	if !b.Retired {
		panic(name + " is not retired")
	}
	b.Retired = false
	emit("BotUnretired", "name", name)
}

// UpgradeBot points an existing bot at new code, keeping its name, rating
// and record. Call it from the new bot realm's init, sent by the bot's owner:
//
//	func init(cur realm) { arena.UpgradeBot(cross(cur), "my-bot", &myBotV2{}) }
func UpgradeBot(cur realm, name string, b bot.Bot) {
	if b == nil {
		panic("bot is nil")
	}
	upgrade(cur, name, b, nil)
}

// UpgradeStrategy is UpgradeBot for a bot written as a plain function.
func UpgradeStrategy(cur realm, name string, s bot.Strategy) {
	if s == nil {
		panic("strategy is nil")
	}
	upgrade(cur, name, nil, s)
}

func upgrade(cur realm, name string, impl bot.Bot, fn bot.Strategy) {
	caller := cur.Previous()
	if !caller.IsCode() || caller.IsEphemeral() {
		panic("upgrades must come from a deployed realm, so the new source is public")
	}
	b := mustBot(name)
	if currentOrigin() != b.Owner {
		panic("only the owner of " + name + " can upgrade it")
	}
	newRealm := caller.PkgPath()
	if newRealm == b.Realm {
		panic("the new version must live in a new realm")
	}
	reserveRealmSlot(newRealm)
	b.History = appendHistory(b.History, b.Realm)
	b.Realm = newRealm
	b.Version++
	b.impl, b.fn = impl, fn
	emit("BotUpgraded", "name", name, "realm", newRealm, "version", strconv.Itoa(b.Version))
}

// appendHistory adds a realm to a bot's "realm@block," history.
func appendHistory(h, realmPath string) string {
	return h + realmPath + "@" + strconv.FormatInt(height(), 10) + ","
}

// PreviousVersions lists the realms a bot used before its current one, oldest
// first.
func (b *Bot) PreviousVersions() []string {
	var out []string
	for _, e := range strings.Split(b.History, ",") {
		if at := strings.LastIndex(e, "@"); at > 0 {
			out = append(out, e[:at])
		}
	}
	return out
}
