package oracle

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

// Render builds the feed's public web page. It is a free read-only query, not a
// transaction, so it must never panic - a page that fails to render looks like a
// dead feed even when the numbers are fine. Every lookup here degrades to text.
//
// Ledger O17: this Render page IS the v0 dashboard. No custom frontend until
// the owner's design gate.
func Render(path string) string {
	switch path {
	case "", "/":
		return renderDashboard()
	case "help":
		return renderHelp()
	default:
		return "unknown path: " + path + "\n\ntry:\n  (nothing)  feed health dashboard\n  help       consumer integration guide\n"
	}
}

func renderDashboard() string {
	height := runtime.ChainHeight()
	var b strings.Builder

	b.WriteString("# GNOT/USD price feed\n\n")
	b.WriteString("chain height: " + strconv.FormatInt(height, 10) + "\n")
	b.WriteString("admin:        " + admin.String() + "\n")
	b.WriteString("config:       staleness " + strconv.FormatInt(cfg.stalenessBlocks, 10) +
		" blocks | deviation limit " + formatBps(cfg.deviationBps) +
		" | quorum " + strconv.Itoa(cfg.minFreshSources) + " fresh source(s)\n")

	if cfg.paused {
		b.WriteString("\n*** PAUSED *** the feed is refusing every read and write until the admin unpauses it.\n")
	}

	if feeds.Size() == 0 {
		b.WriteString("\nno assets registered yet.\n")
		return b.String()
	}

	feeds.Iterate("", "", func(asset string, value any) bool {
		f, ok := value.(*feed)
		if !ok {
			return false
		}
		b.WriteString(renderFeed(f, height))
		return false
	})

	return b.String()
}

func renderFeed(f *feed, height int64) string {
	var b strings.Builder

	b.WriteString("\n## " + f.asset + "\n\n")

	fresh := f.countFresh(height)
	consistent := len(f.consistentFresh(height))
	total := f.sources.Size()
	quorum := fresh >= cfg.minFreshSources

	b.WriteString("published median: ")
	if !f.published {
		b.WriteString("none yet (waiting for " + strconv.Itoa(cfg.minFreshSources) + " fresh sources)\n")
	} else {
		b.WriteString(formatUSD(f.median) + "  (" + strconv.FormatInt(int64(f.median), 10) + " raw)\n")
		b.WriteString("  published at height " + strconv.FormatInt(f.medianAt, 10) +
			", " + formatAge(feedmath.BlockAge(f.medianAt, height)) + " ago" +
			", from " + strconv.Itoa(f.included) + " source(s)\n")
	}

	answer := "REFUSING (not enough fresh sources)"
	if quorum && f.published && feedmath.IsFresh(f.medianAt, height, cfg.stalenessBlocks) && !cfg.paused {
		answer = "ANSWERING"
	} else if cfg.paused {
		answer = "REFUSING (paused)"
	} else if f.published && !feedmath.IsFresh(f.medianAt, height, cfg.stalenessBlocks) {
		answer = "REFUSING (median is stale)"
	}
	b.WriteString("GetPrice status:  " + answer + "\n")
	b.WriteString("quorum:           " + strconv.Itoa(fresh) + " of " + strconv.Itoa(total) +
		" sources fresh (" + strconv.Itoa(consistent) + " consistent, needs " +
		strconv.Itoa(cfg.minFreshSources) + ")\n")

	b.WriteString("\n| source | price | age (blocks) | status | key | rejected |\n")
	b.WriteString("|--------|-------|--------------|--------|-----|----------|\n")

	if total == 0 {
		b.WriteString("| (none registered) | | | | | |\n")
		return b.String()
	}

	f.sources.Iterate("", "", func(sourceID string, value any) bool {
		s, ok := value.(*source)
		if !ok {
			return false
		}

		price := "n/a"
		age := "n/a"
		status := "NO DATA"
		if s.hasSubmission {
			price = formatUSD(s.price)
			age = formatAge(feedmath.BlockAge(s.height, height))
			switch {
			case !s.isFresh(height):
				status = "STALE"
			case f.isOutlier(s, height):
				// Fresh, stored, but culled from the consistent subset (ledger
				// O19): it disagrees with the fresh set's median and does not
				// contribute to the published number. A compromised or badly
				// broken feeder looks exactly like this.
				status = "OUTLIER"
			default:
				status = "FRESH"
			}
		}

		rejections := strconv.FormatInt(s.rejected, 10)
		if s.rejected > 0 {
			rejections += " (last " + formatBps(s.lastRejectBps) + " off)"
		}

		b.WriteString("| " + sourceID +
			" | " + price +
			" | " + age +
			" | " + status +
			" | " + s.keyAddr.String() +
			" | " + rejections + " |\n")
		return false
	})

	return b.String()
}

func renderHelp() string {
	return `# Consuming this feed

## Reading a price

    import oracle "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"

    price, height := oracle.GetPrice("GNOT")   // price is an integer scaled by 1e6

## GetPrice PANICS when it cannot be trusted

That is the design, not a bug. It reverts when the feed is paused, when fewer
than the configured quorum of sources are fresh, or when the published median is
older than the staleness window. A consumer that ignores this will freeze at the
worst possible moment, so handle it:

    // in a crossing function of your own realm
    price, height := oracle.GetPrice("GNOT")   // let it revert your tx, or:

Isolating the call so you can react to the failure requires the caller to decide
what a frozen feed means for them. The demo realm in this project renders an
explicit "FEED UNAVAILABLE" state instead of showing a stale number.

## Converting a price to a display value

Prices are integers scaled by 1e6 (ledger O7 - no floats on chain):

    usd := float64(price) / 1e6        // OFF CHAIN ONLY, for display
    // on chain, keep integer math: dollars := int64(price) / 1000000

## Submitting a price

Only a key registered for a specific source may submit for it. Registering a
source is admin-only.

    gnokey maketx call -pkgpath "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0" \
      -func SubmitPrice -args kucoin -args GNOT -args 49050 \
      -gas-fee 200000ugnot -gas-wanted 4000000 \
      -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 feeder-kucoin

A submission that deviates too far from the other fresh sources is REJECTED: the
transaction succeeds, the price is not stored, and the dashboard shows the
rejection count and how far off it was.
`
}

// ---- formatting helpers --------------------------------------------------
//
// Integer math only. These exist so neither the dashboard nor GetSources can
// drift from how a price really is encoded.

// formatUSD renders a scaled price as dollars, e.g. 49050 -> "$0.049050".
// A non-positive price is not a quote, so it renders as "n/a" rather than $0.
func formatUSD(p feedmath.Price) string {
	if p <= 0 {
		return "n/a"
	}
	whole := int64(p) / feedmath.Scale
	frac := int64(p) % feedmath.Scale
	return "$" + strconv.FormatInt(whole, 10) + "." + padLeft(frac, 6)
}

// formatBps renders basis points as a percentage, e.g. 1000 -> "10.00%".
func formatBps(bps int64) string {
	whole := bps / 100
	frac := bps % 100
	if frac < 0 {
		frac = -frac
	}
	return strconv.FormatInt(whole, 10) + "." + padLeft(frac, 2) + "%"
}

// formatAge renders a block age, or "n/a" when there is nothing to date from.
func formatAge(age int64) string {
	if age < 0 {
		return "n/a"
	}
	return strconv.FormatInt(age, 10)
}

// padLeft zero-pads n to width digits. Needed because a fractional part loses
// its leading zeros when formatted as a plain integer: 49050 % 1e6 = 49050,
// which must print as "049050", not "49050".
func padLeft(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}
