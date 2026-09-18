// Package guilds records which Discord server a court's moderators chose.
//
// WHY A SEPARATE REALM. kourtv2 is deployed and knows nothing about Discord, and
// a realm on chain is not edited — adding a field there means a new realm and a
// migration for every court that exists. This holds one string per court and
// asks kourtv2 who may set it, so the court's own moderator list stays the only
// authority and this file never has one of its own.
//
// WHY IT EXISTS AT ALL, when the service could verify a signed message and did.
// It could, and the signature had to be made at a terminal, because a wallet
// signs TRANSACTIONS and not arbitrary strings. So the last step of standing up
// a court's Discord server was a command nobody would ever discover, and the
// court page said so and stopped. A realm call IS a transaction, which is
// exactly what a wallet already does — the same button every other action on the
// page uses.
//
// WHAT IT DOES NOT DO. It does not check that the guild exists, that the bot is
// in it, or that anybody can join it. Those are the service's to know and it
// already does; this records a CHOICE, made by an address the court recognises,
// at a height anybody can read back. A guild id here with no bot behind it is a
// court pointing at nothing, which is visible rather than dangerous.
package guilds

import (
	"chain"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"

	kourt "gno.land/r/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/kourt"
)

// choice is what a court's moderators decided: which server, and who said so.
//
// THE SETTER IS STORED, not only emitted. The event carries it too, and the
// event is the history — but kourt.xyz reads this realm over qeval and has no
// indexer, so a service that recorded "listed, signed by" from the event alone
// would need one. Reading it back is one lookup on a page that already does one.
type choice struct {
	guildID string
	by      address
}

// guildOf is court slug -> choice. One server per court: a court with two is a
// court whose readers are told different things by the same page.
//
// A bptree rather than an avl tree because kourtv2 uses one for every ordered
// map it keeps, and Courts() wants slug order.
var guildOf = bptree.NewBPTree32()

// Set records the guild for a court, or clears it when guildID is empty.
//
// THE CALLER IS THE MODERATOR, NOT THIS REALM. cur.Previous().Address() is who
// asked, and kourt.IsCourtMod is the only thing consulted — so a moderator
// removed by the court loses this at the same moment, with no state here to keep
// in step. IsCourtMod panics on a court that does not exist, which is the answer
// we want: there is nothing to bind.
func Set(cur realm, courtSlug, guildID string) {
	if !cur.IsCurrent() {
		panic("guilds: stale realm")
	}
	who := cur.Previous().Address()
	if !kourt.IsCourtMod(courtSlug, who) {
		panic("guilds: only a moderator of this court may set its server")
	}
	id := strings.TrimSpace(guildID)
	if id == "" {
		if _, removed := guildOf.Remove(courtSlug); removed {
			chain.Emit("GuildCleared", "court", courtSlug, "by", who.String())
		}
		return
	}
	// A Discord snowflake is decimal digits, and every id minted since 2015 is
	// 17 to 20 of them. Bounded here so a mistyped paste is refused at the call
	// rather than stored and puzzled over on the page.
	if len(id) < 17 || len(id) > 20 {
		panic("guilds: a Discord server id is 17 to 20 digits")
	}
	for i := 0; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			panic("guilds: a Discord server id is digits only")
		}
	}
	guildOf.Set(courtSlug, choice{guildID: id, by: who})
	chain.Emit("GuildSet", "court", courtSlug, "guild", id, "by", who.String())
}

// GuildOf is the court's chosen server, or "" if it has none. Never panics: the
// service asks this about every court it knows, including ones that never chose.
func GuildOf(courtSlug string) string {
	c, ok := guildOf.Get(courtSlug).(choice)
	if !ok {
		return ""
	}
	return c.guildID
}

// Chosen is the whole record: the server, and the address that chose it.
//
// ONE READ AND NOT TWO, and this exists for that reason alone. kourt.xyz asks
// both questions together and acts on the pair — it publishes the guild AND
// records the setter as who signed for it — and two qeval calls can straddle a
// change. A moderator re-aiming the binding between them hands one decision's
// guild to another decision's signer, which is then written into the site's
// database as fact. A pair that cannot be read atomically should not be read as a
// pair.
//
// BOTH EMPTY OR NEITHER. A court that never chose answers ("", ""), which is the
// commonest answer and is not an error.
//
// THE SETTER IS WHO ASKED, NOT WHO MODERATES NOW. A court that replaces its
// moderators does not change this — the choice was made by whoever made it, and
// rewriting that would destroy the only record of who did. Whether they STILL
// moderate is a separate question, and kourtv2 is the one to ask it.
//
// STRINGS AND NOT AN address, because the caller is a machine reading qeval's
// printed output: an address prints as `("g1…" .uverse.address)` and a string as
// `("g1…" string)`, and the second is the one a parser can hold to.
func Chosen(courtSlug string) (guildID, by string) {
	c, ok := guildOf.Get(courtSlug).(choice)
	if !ok {
		return "", ""
	}
	return c.guildID, c.by.String()
}

// Courts lists every court that has chosen a server, in slug order — so the
// service can reconcile the whole set without knowing what to ask for.
func Courts() []string {
	out := []string{}
	guildOf.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Court Discord servers\n\n")
	b.WriteString("Which Discord server each court's moderators chose. ")
	b.WriteString("Set by a moderator of the court, read by kourt.xyz.\n\n")
	n := 0
	guildOf.Iterate("", "", func(k string, v any) bool {
		c, _ := v.(choice)
		b.WriteString("- **" + k + "** — `" + c.guildID + "` (set by " + c.by.String() + ")\n")
		n++
		return false
	})
	if n == 0 {
		b.WriteString("_No court has chosen one yet._\n")
	}
	return b.String()
}
