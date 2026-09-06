package incentives

import (
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	out := "# zdex incentives v1\n\n"
	out += "Sidecar gauges on DexPkg. Native `ugnot` via OriginSend. LP Claim uses LastLP; does not call zdex swap or LP.\n\n"
	if paused {
		out += "> [!CAUTION]\n> Funding is paused. Claim still works.\n\n"
	}
	out += ufmt.Sprintf("* Version: **%s**\n* Dex: `%s`\n* Admin: `%s`\n\n", Version(), DexPkg(), admin.String())

	out += "## Gauges\n\n"
	if gauges.Size() == 0 {
		out += "_None yet._\n\n"
	} else {
		out += "| Pool | acc | funded | on |\n|---|---:|---:|---|\n"
		gauges.Iterate("", "", func(_ string, v any) bool {
			g := v.(*Gauge)
			on := "off"
			if g.On {
				on = "on"
			}
			out += ufmt.Sprintf("| `%s` | %d | %d | %s |\n", sanitize.InlineText(g.ID), g.Acc, g.TotalFunded, on)
			return false
		})
		out += "\n"
	}

	out += "## Fund\n\n"
	out += "Attach `ugnot` with the tx. Any EOA can incentivize a live pool (`totalLP > 0`).\n\n"
	out += "<gno-form exec=\"Fund\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "</gno-form>\n\n"

	out += "## Claim\n\n"
	out += "Settles LastLP then snapshots current PositionOf. Works when paused or gauge off.\n\n"
	out += "<gno-form exec=\"Claim\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "</gno-form>\n"
	return out
}
