package incentives

import (
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	out := "# zdex incentives v4\n\n"
	out += "Sidecar gauges on DexPkg. Native `ugnot` via OriginSend. Lump `Fund` or timed `FundProgram` (stacks Remaining). SweepDust is owner+paused only and never takes Owed. LP Claim uses LastLP; does not call zdex swap or LP.\n\n"
	if paused {
		out += "> [!CAUTION]\n> Funding is paused. Claim still works.\n\n"
	}
	out += ufmt.Sprintf("* Version: **%s**\n* Dex: `%s`\n* Admin: `%s`\n\n", Version(), DexPkg(), admin.String())

	out += "## Gauges\n\n"
	if gauges.Size() == 0 {
		out += "_None yet._\n\n"
	} else {
		out += "| Pool | acc | funded | on | end | rpb | rem |\n|---|---:|---:|---|---:|---:|---:|\n"
		gauges.Iterate("", "", func(_ string, v any) bool {
			g := v.(*Gauge)
			accrue(g)
			on := "off"
			if g.On {
				on = "on"
			}
			out += ufmt.Sprintf("| `%s` | %d | %d | %s | %d | %d | %d |\n", sanitize.InlineText(g.ID), g.Acc, g.TotalFunded, on, g.EndH, g.RewardPerBlock, g.Remaining)
			return false
		})
		out += "\n"
	}

	out += "## Fund\n\n"
	out += "Attach `ugnot` with the tx. Lump credit to Acc (duration 0). Any EOA can incentivize a live pool (`totalLP > 1000`).\n\n"
	out += "<gno-form exec=\"Fund\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "</gno-form>\n\n"

	out += "## FundProgram\n\n"
	out += "Timed emission. `durationBlocks >= 28800`. Acc grows on accrue, not at deposit. A later FundProgram stacks leftover Remaining.\n\n"
	out += "<gno-form exec=\"FundProgram\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "<gno-input name=\"durationBlocks\" placeholder=\"28800\" required=\"true\" />\n"
	out += "</gno-form>\n\n"

	out += "## Claim\n\n"
	out += "Settles LastLP then snapshots current PositionOf. Works when paused or gauge off.\n\n"
	out += "<gno-form exec=\"Claim\">\n"
	out += "<gno-input name=\"poolID\" placeholder=\"ugnot|SYMBOL\" required=\"true\" />\n"
	out += "</gno-form>\n"
	return out
}
