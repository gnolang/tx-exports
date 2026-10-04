package skins

import "strings"

// Render returns the shop as markdown, for gnoweb:
//
//	""               the catalog
//	"skin/<id>"      one design
//	"player/<addr>"  the skins of one address
//
// Everything printed went through validate.gno when it was written, or is
// an address the chain gave the realm; the caller-supplied id and address are
// printed only once found valid.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case strings.HasPrefix(path, "skin/"):
		if d := getDesign(strings.TrimPrefix(path, "skin/")); d != nil {
			return renderDesign(d)
		}
	case strings.HasPrefix(path, "player/"):
		if addr := address(strings.TrimPrefix(path, "player/")); validAddress(addr) {
			return renderPlayer(addr)
		}
	}
	return "# gnofly skins\n\nPage not found. Go back to the [shop](" + link("") + ").\n"
}

func link(path string) string {
	if path == "" {
		return webPath
	}
	return webPath + ":" + path
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# gnofly skins\n\n")
	b.WriteString("Paint jobs for the planes of gnofly. Each one bought is a token bound to its buyer: it cannot be\n")
	b.WriteString("transferred. Buy one with `Buy` and its price attached, then fly it from the hangar of the game.\n")
	b.WriteString("Classic is free for everyone and is not sold here.\n\n")
	b.WriteString("| Skin | Model | Price | Sold | Supply | For sale |\n|---|---|---|---|---|---|\n")
	designs.Iterate("", "", func(_ string, v any) bool {
		d := v.(*design)
		b.WriteString("| " + designLink(d) + " | " + d.model + " | " + gnot(d.price) + " | " + itoa(d.minted) +
			" | " + supplyText(d.maxSupply) + " | " + yesNo(d.listed) + " |\n")
		return false
	})
	b.WriteString("\nTreasury: " + roles.Treasury().String() + "\n")
	return b.String()
}

func renderDesign(d *design) string {
	var b strings.Builder
	b.WriteString("# " + d.name + "\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Id | " + d.id + " |\n")
	b.WriteString("| Model | " + d.model + " |\n")
	b.WriteString("| Pilot | " + d.pilot + " |\n")
	b.WriteString("| Body | `" + d.body + "` |\n")
	b.WriteString("| Wing | `" + d.wing + "` |\n")
	b.WriteString("| Accent | `" + d.accent + "` |\n")
	b.WriteString("| Price | " + gnot(d.price) + " |\n")
	b.WriteString("| Sold | " + itoa(d.minted) + " of " + supplyText(d.maxSupply) + " |\n")
	b.WriteString("| For sale | " + yesNo(d.listed) + " |\n")
	b.WriteString("| Metadata | `" + uriBase + d.id + ".json` |\n")
	b.WriteString("\n[Shop](" + link("") + ")\n")
	return b.String()
}

func renderPlayer(addr address) string {
	var b strings.Builder
	b.WriteString("# Pilot " + addr.String() + "\n\n")
	n := 0
	prefix := addr.String() + "/"
	owned.Iterate(prefix, addr.String()+"0", func(key string, v any) bool {
		if n == 0 {
			b.WriteString("| Skin | Token |\n|---|---|\n")
		}
		d := getDesign(strings.TrimPrefix(key, prefix))
		if d != nil {
			b.WriteString("| " + designLink(d) + " | " + itoa(v.(int64)) + " |\n")
		}
		n++
		return false
	})
	if n == 0 {
		b.WriteString("No skin yet: this pilot flies Classic.\n")
	}
	b.WriteString("\n[Shop](" + link("") + ")\n")
	return b.String()
}

func designLink(d *design) string {
	return "[" + d.name + "](" + link("skin/"+d.id) + ")"
}

func supplyText(n int64) string {
	if n == 0 {
		return "unlimited"
	}
	return itoa(n)
}

// gnot writes ugnot as GNOT: 1000000 -> "1 GNOT", 1500000 -> "1.5 GNOT".
func gnot(ugnot int64) string {
	whole, frac := ugnot/1000000, ugnot%1000000
	if frac == 0 {
		return itoa(whole) + " GNOT"
	}
	f := itoa(frac + 1000000)[1:]
	for f[len(f)-1] == '0' {
		f = f[:len(f)-1]
	}
	return itoa(whole) + "." + f + " GNOT"
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
