package heirloom

import (
	"strings"

	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/nt/ufmt/v0"
)

func renderHome() string {
	active, gnotHeld, released := totals()

	var b strings.Builder
	b.WriteString("# Heirloom\n\n")
	b.WriteString("Leave your GNOT and tokens to the people you choose, and your admin rights in realms that check `Holder`. ")
	b.WriteString("If you show no sign of life for the period you set, anyone else can release the will and pay out your heirs' shares. ")
	b.WriteString("Until then everything stays yours. Every successful call you sign to Heirloom restarts the clock, and so does using a realm that calls `Touch`. ")
	b.WriteString("Other activity on the chain and transactions signed with a session key do not, and a session key cannot create, change or ping a will: sign those with your master key.\n\n")

	b.WriteString("| Unreleased wills | GNOT held | Wills released |\n| :---: | :---: | :---: |\n")
	b.WriteString(ufmt.Sprintf("| %d | %s | %d |\n\n", active, describe(gnot).amount(gnotHeld), released))

	b.WriteString("## Make a will\n\n")
	b.WriteString("List heirs as `address:percent`, separated by commas; the percentages must add up to 100, and the first heir gets any remainder left by rounding. ")
	b.WriteString("Your successor is whoever should inherit your admin rights in realms that check `Holder`: an heir or anyone else. Leave it empty to keep them. ")
	b.WriteString("Admin rights are handed over once, by the first released will whose successor can take them; later wills only leave assets.\n\n")
	b.WriteString(mdform.New("exec", "CreateWill").
		Input("heirs", "placeholder", "g1...:70, g1...:30", "description", "Heirs and their percentages").
		Input("silence", "type", mdform.InputTypeNumber, "value", "180", "description", ufmt.Sprintf("How many days you may stay silent, from %d to %d", int(MinSilence/day), int(MaxSilence/day))).
		Input("successor", "placeholder", "g1...", "description", "Successor (optional)").
		String() + "\n\n")
	b.WriteString("Your wills and the wills that name you as heir or successor are at `" + webPath + ":u/<your address>`.\n\n")

	if recent := recentlyReleased(); len(recent) > 0 {
		b.WriteString("## Recently released\n\n")
		for _, w := range recent {
			b.WriteString("- " + willLink(w.ID) + " of " + userLink(w.Owner) + ", " + formatTime(w.ReleasedAt) + "\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## For realm developers\n\n")
	b.WriteString("Let admin rights pass to the successor, and count every use of your realm, admin actions included, as a sign of life:\n\n")
	b.WriteString("```go\nimport \"" + pkgPath + "\"\n\n")
	b.WriteString("var admin = address(\"g1...\")\n\n")
	b.WriteString("func AdminOnly(cur realm) {\n\tif !cur.IsCurrent() || cur.Previous().Address() != heirloom.Holder(admin) {\n\t\tpanic(\"admin only\")\n\t}\n\theirloom.Touch(cross(cur))\n}\n\n")
	b.WriteString("func Use(cur realm) {\n\theirloom.Touch(cross(cur))\n}\n```\n\n")
	b.WriteString("`Touch` only vouches for the account that signed the transaction, so no realm can keep someone else's will from being released. It ignores transactions signed with a session key, so an admin who works through a session key also needs to call `Ping` now and then. ")
	b.WriteString("`Holder` returns the address itself until a released will of that address hands its admin rights on, then the holder of that successor's rights.\n")
	return b.String()
}
