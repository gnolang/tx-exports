package guildsv3
import (
	"chain"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
	kourt "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3"
)
type choice struct {
	guildID string
	by      address
}
var guildOf = bptree.NewBPTree32()
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
func GuildOf(courtSlug string) string {
	c, ok := guildOf.Get(courtSlug).(choice)
	if !ok {
		return ""
	}
	return c.guildID
}
func Chosen(courtSlug string) (guildID, by string) {
	c, ok := guildOf.Get(courtSlug).(choice)
	if !ok {
		return "", ""
	}
	return c.guildID, c.by.String()
}
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
