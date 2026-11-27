// Package arena runs matches between bots that other people deploy as their
// own realms. Every turn the arena calls each bot's code, so the chain is the
// referee and every bot's source is public.
//
// Matches have two speeds:
//
//   - Fast: Play (or Fight) runs a whole match in one transaction.
//   - Step: if a match can't finish in one transaction (a bot crashes or runs
//     out of gas), StartStepMode switches it to one move per SubmitMove
//     transaction. The bot whose move can't be made misses its deadline and
//     ClaimForfeit records the loss. Crashing can't save a bot from a loss.
package arena

import (
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/nt/avl/v0"
)

const (
	maxBotsPerRealm = 5
	startRating     = 1200
)

// Bot is a registered bot.
type Bot struct {
	Name       string
	Realm      string  // realm that registered it; its source is public
	Owner      address // account that sent the registering transaction
	Registered int64   // block height
	Rating     int
	Wins       int
	Losses     int
	Draws      int
	Forfeits   int // losses by forfeit, also counted in Losses

	// season record, reset when a new season starts (see season.gno)
	SeasonWins, SeasonLosses, SeasonDraws int

	// owner tools (see owner.gno)
	Description string
	Retired     bool
	Version     int    // 1 at registration, +1 per upgrade
	History     string // "realm@block," of previous versions

	impl        bot.Bot
	fn          bot.Strategy
	recentRated string // "opponent@block," for recent rated matches, see claimRatedSlot
}

// Played is the number of finished matches.
func (b *Bot) Played() int { return b.Wins + b.Losses + b.Draws }

var (
	bots         = avl.NewTree() // name -> *Bot
	botsPerRealm = avl.NewTree() // realm path -> int
)

// RegisterBot enters a bot with a Move method. Call it from your bot realm,
// usually in init:
//
//	func init(cur realm) { arena.RegisterBot(cross(cur), "my-bot", &myBot{}) }
func RegisterBot(cur realm, name string, b bot.Bot) {
	if b == nil {
		panic("bot is nil")
	}
	register(cur, name, &Bot{impl: b})
}

// RegisterStrategy enters a bot written as a plain function. A function
// declared in a /p/ package has one extra guarantee: if it crashes, the arena
// can catch it straight away and score a forfeit without step mode.
func RegisterStrategy(cur realm, name string, s bot.Strategy) {
	if s == nil {
		panic("strategy is nil")
	}
	register(cur, name, &Bot{fn: s})
}

func register(cur realm, name string, b *Bot) {
	caller := cur.Previous()
	if !caller.IsCode() || caller.IsEphemeral() {
		panic("bots must be registered by a deployed realm, so their source is public")
	}
	if err := validName(name); err != "" {
		panic(err)
	}
	if bots.Has(name) {
		panic("bot name already taken: " + name)
	}
	realmPath := caller.PkgPath()
	reserveRealmSlot(realmPath)
	b.Name = name
	b.Realm = realmPath
	b.Owner = currentOrigin()
	b.Registered = height()
	b.Rating = startRating
	b.Version = 1
	bots.Set(name, b)
	emit("BotRegistered", "name", name, "realm", realmPath)
}

// reserveRealmSlot counts one more bot for realmPath, up to maxBotsPerRealm.
func reserveRealmSlot(realmPath string) {
	count := 0
	if v := botsPerRealm.Get(realmPath); v != nil {
		count = v.(int)
	}
	if count >= maxBotsPerRealm {
		panic("this realm already registered the maximum number of bots")
	}
	botsPerRealm.Set(realmPath, count+1)
}

func currentOrigin() address { return unsafe.OriginCaller() }

func validName(name string) string {
	if len(name) < 3 || len(name) > 24 {
		return "bot names must be 3 to 24 characters"
	}
	for i, c := range name {
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c == '-' && i > 0 && i < len(name)-1)
		if !ok {
			return "bot names may only use a-z, 0-9 and inner dashes"
		}
	}
	if strings.Contains(name, "--") {
		return "bot names may not contain --"
	}
	return ""
}

func mustBot(name string) *Bot {
	v := bots.Get(name)
	if v == nil {
		panic("unknown bot: " + name)
	}
	return v.(*Bot)
}

// ask gets one move from b. A crash inside a /p/ function bot is caught and
// reported; a crash inside realm code aborts the transaction (Gno does not
// let the caller recover it), which is what step mode is for.
func (b *Bot) ask(s bot.State) (a bot.Action, crashed bool) {
	defer func() {
		if r := recover(); r != nil {
			crashed = true
		}
	}()
	if b.impl != nil {
		return b.impl.Move(s), false
	}
	return b.fn(s), false
}

// BotInfo describes a bot for other realms and off-chain tools.
type BotInfo struct {
	Name, Realm, Description                      string
	Owner                                         address
	Rating, Wins, Losses, Draws, Forfeits, Played int
	Retired                                       bool
	Version                                       int
}

// GetBot returns public information about a bot.
func GetBot(name string) (BotInfo, bool) {
	v := bots.Get(name)
	if v == nil {
		return BotInfo{}, false
	}
	b := v.(*Bot)
	return BotInfo{
		Name: b.Name, Realm: b.Realm, Description: b.Description, Owner: b.Owner,
		Rating: b.Rating, Wins: b.Wins, Losses: b.Losses, Draws: b.Draws, Forfeits: b.Forfeits,
		Played: b.Played(), Retired: b.Retired, Version: b.Version,
	}, true
}

// BotCount is the number of registered bots.
func BotCount() int { return bots.Size() }
