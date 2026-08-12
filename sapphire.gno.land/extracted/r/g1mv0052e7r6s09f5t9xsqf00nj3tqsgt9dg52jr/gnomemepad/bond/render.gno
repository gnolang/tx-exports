package bond

import (
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	_ = path
	out := "# gnomemepad create-bond policy\n\n"
	out += "Separate realm — pad upgrades do not replace this schedule.\n\n"
	if !inited {
		out += "> [!CAUTION]\n> Call Init first.\n"
		return out
	}
	out += ufmt.Sprintf("- **Current bond:** %d ugnot (~%d GNOT)\n", CurrentBondUgnot(), CurrentBondUgnot()/1_000_000)
	out += ufmt.Sprintf("- **Normal bond:** %d ugnot\n", normalBondUgnot)
	out += ufmt.Sprintf("- **Promo bond:** %d ugnot\n", promoBondUgnot)
	if IsPromoActive() {
		out += ufmt.Sprintf("- **Promo active** — ends at unix %d (~%d s left)\n", promoEndsAt, PromoSecondsLeft())
	} else {
		out += "- Promo: inactive (using normal bond)\n"
	}
	out += ufmt.Sprintf("- Admin: `%s`\n\n", admin.String())
	out += "## API\n\n"
	out += "- `CurrentBondUgnot()` — pad reads this on Create\n"
	out += "- `StartPromo(promoUgnot, durationSec)` — admin; 0 amount keeps set promo bond; 0 duration → 10d\n"
	out += "- `EndPromo()` — admin → normal bond immediately\n"
	out += "- `SetNormalBond` / `SetPromoBond` / `ExtendPromo`\n"
	out += "- `BondInfo()` → status|current|normal|promo|endsAt|left|admin\n"
	_ = strconv.Itoa(0)
	return out
}
