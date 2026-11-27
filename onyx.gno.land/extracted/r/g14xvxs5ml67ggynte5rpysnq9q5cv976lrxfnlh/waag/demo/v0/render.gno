package demo

// Render for the demo vault. Same rule as the oracle's Render: a free
// read-only query that must NEVER panic - a page that fails to load looks
// like a dead vault even when the positions are fine.
//
// The formatting helpers are deliberate copies of the oracle realm's (its
// render.gno): they are unexported there, and importing display helpers
// across a realm boundary is not worth the coupling for a v0 demo. Same
// integer-only rules (ledger O7) - no floats anywhere.

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
	oracle "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"
)

// Render builds the demo vault's public web page (ledger O17: this page IS
// the v0 frontend; no custom UI until the owner's design gate).
func Render(path string) string {
	switch path {
	case "", "/":
		return renderDashboard()
	case "help":
		return renderHelp()
	default:
		return "unknown path: " + path + "\n\ntry:\n  (nothing)  vault dashboard\n  help       how this demo consumes the feed\n"
	}
}

// safeFeedProbe is the dashboard's ONLY contact with the oracle. It pairs
// the check-then-call gate (feedAnswering, proven sufficient in the package
// doc) with a belt-and-braces recover: the probe functions call
// oracle.GetSources, which panics on a never-registered asset. The deploy
// runbook makes that state unreachable on a real chain (oracle + sources
// are registered before this realm is deployed), and the recover covers it
// everywhere else - Render degrades to "UNAVAILABLE" instead of failing.
func safeFeedProbe() (answering bool, status string, price feedmath.Price, priceAt int64) {
	defer func() {
		if recover() != nil {
			answering = false
			status = "UNAVAILABLE (oracle state could not be read)"
			price = 0
			priceAt = 0
		}
	}()
	if !feedAnswering() {
		return false, feedStatusText(), 0, 0
	}
	p, h := oracle.GetPrice(Asset)
	return true, "ANSWERING", p, h
}

func renderDashboard() string {
	height := runtime.ChainHeight()
	answering, status, price, priceAt := safeFeedProbe()

	var b strings.Builder
	b.WriteString("# The Waag - demo vault (MOCK)\n\n")
	b.WriteString("chain height: " + strconv.FormatInt(height, 10) + "\n")
	b.WriteString("admin:        " + admin.String() + "\n")
	b.WriteString("asset:        " + Asset + "\n")
	b.WriteString("oracle:       " + OraclePath + "\n")
	b.WriteString("underwater threshold: " + formatBps(thresholdBps) + " below entry\n")
	b.WriteString("\nMOCK vault: positions are test numbers. No real GNOT is held or moved.\n")

	b.WriteString("\n## Feed\n\n")
	if answering {
		b.WriteString("status: ANSWERING at " + formatUSD(price) +
			" (published at height " + strconv.FormatInt(priceAt, 10) +
			", " + strconv.FormatInt(feedmath.BlockAge(priceAt, height), 10) +
			" blocks ago)\n")
	} else {
		b.WriteString("*** FEED FROZEN *** " + status + "\n")
		b.WriteString("deposits revert while frozen; withdrawals stay open; valuations show n/a.\n")
	}

	b.WriteString("\n## Positions\n\n")
	if positions.Size() == 0 {
		b.WriteString("(no open positions)\n")
		return b.String()
	}

	totalText := "too large to sum"
	if total, ok := totalMockUGNOT(); ok {
		totalText = formatGNOT(total)
	}
	b.WriteString("open positions: " + strconv.Itoa(positions.Size()) +
		" (total mock " + totalText + ")\n\n")

	b.WriteString("| depositor | mock GNOT | entry | value now | health | status |\n")
	b.WriteString("|-----------|-----------|-------|-----------|--------|--------|\n")

	positions.Iterate("", "", func(_ string, value any) bool {
		p, isPos := value.(*position)
		if !isPos {
			return false // keep going; a malformed entry must not stop the page
		}
		valNow, health, state := "n/a", "n/a", "FROZEN"
		if answering {
			if v, fits := valueMicroUSD(p.amountUGNOT, price); fits {
				valNow = formatUSD(feedmath.Price(v))
			} else {
				valNow = "too large"
			}
			health = strconv.FormatInt(healthPct(p.entryPrice, price), 10) + "%"
			if isUnderwater(p.entryPrice, price) {
				state = "UNDERWATER"
			} else {
				state = "OK"
			}
		}
		b.WriteString("| " + p.depositor.String() +
			" | " + formatGNOT(p.amountUGNOT) +
			" | " + formatUSD(p.entryPrice) +
			" | " + valNow +
			" | " + health +
			" | " + state + " |\n")
		return false
	})

	b.WriteString("\nfrozen positions keep their entry prices as evidence; nothing is hidden or deleted while the feed is down.\n")
	return b.String()
}

// totalMockUGNOT sums open position sizes. Each size is capped at
// MaxPositionUGNOT, but the running sum is overflow-guarded anyway: a
// display helper must never be the thing that wraps around.
func totalMockUGNOT() (int64, bool) {
	total := int64(0)
	fits := true
	positions.Iterate("", "", func(_ string, value any) bool {
		p, isPos := value.(*position)
		if !isPos {
			return false
		}
		if fits && total <= maxInt64-p.amountUGNOT {
			total += p.amountUGNOT
		} else {
			fits = false
		}
		return false
	})
	return total, fits
}

func renderHelp() string {
	return `# How this demo consumes The Waag feed

MOCK vault (ledger O14): positions are test numbers valued through
` + OraclePath + `. No real GNOT is held, no borrowing, no interest.

## The check-then-call pattern (the point of this realm)

oracle.GetPrice PANICS when the feed cannot be trusted, and a panic that
crosses a realm boundary cannot be caught in production - revive() is a
test-mode builtin only. So this realm NEVER tries to catch it. It checks
first with two non-panicking reads, and only then calls:

    _, _, minFresh, paused := oracle.Config()
    fresh, _ := parseFreshCount(oracle.GetSources("GNOT"))  // header: fresh=N/M
    if !paused && fresh >= minFresh {
        price, height := oracle.GetPrice("GNOT")            // cannot panic now
    }

Why that check is sufficient is proved in this realm's package docs: if
enough sources are fresh NOW, the newest fresh submission already republished
a fresh median, so none of GetPrice's panic conditions can hold.

## What a frozen feed means here

- Deposit  REVERTS with the reason (no price, no position, no guessing).
- Withdraw is ALWAYS allowed - mock funds are never held hostage by a dead
  feed. The closing event records feed=frozen instead of a realized pnl.
- The dashboard degrades to "*** FEED FROZEN ***" plus the reason, and shows
  n/a where a live price would be. Stored positions keep their entry prices
  as evidence; nothing is hidden or deleted while the feed is down.

## Underwater rule

A position is UNDERWATER when the fed price sits at least the threshold
(default 10.00%) below its entry price. The admin retunes it with
SetThreshold(bps), range [0, 10000].

## Calling it

    gnokey maketx call -pkgpath "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/demo/v0" ` +
		`\
      -func Deposit -args 500000000 \
      -gas-wanted <simulate first> -gas-fee <simulate first> \
      -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 test1

Deposit takes mock ugnot (500000000 = 500 GNOT); Withdraw takes no args.
Always measure gas with -simulate only first (see scripts/deploy.sh - the
empty-state simulation UNDER-sizes state-dependent calls; that trap is in
the master doc §13).

## Events

VaultPositionOpened / VaultPositionClosed / VaultThresholdChanged, emitted
via chain.Emit with everything an off-chain watcher needs - including
realized pnl_bps and whether the feed was answering at withdrawal.
`
}

// ---- formatting helpers (integer math only) --------------------------------

// formatUSD renders a scaled price as dollars, e.g. 45050 -> "$0.045050".
// A non-positive price is not a quote, so it renders as "n/a" rather than $0.
func formatUSD(p feedmath.Price) string {
	if p <= 0 {
		return "n/a"
	}
	whole := int64(p) / feedmath.Scale
	frac := int64(p) % feedmath.Scale
	return "$" + strconv.FormatInt(whole, 10) + "." + padLeft(frac, 6)
}

// formatGNOT renders mock ugnot as GNOT: 500000000 -> "500.000000 GNOT".
// ugnot uses the same 1e6 scale as feedmath prices, hence feedmath.Scale.
func formatGNOT(ugnot int64) string {
	if ugnot < 0 {
		ugnot = 0
	}
	whole := ugnot / feedmath.Scale
	frac := ugnot % feedmath.Scale
	return strconv.FormatInt(whole, 10) + "." + padLeft(frac, 6) + " GNOT"
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

// padLeft zero-pads n to width digits: fractional parts lose leading zeros
// when formatted plainly (45050 % 1e6 = 45050 must print as "045050").
func padLeft(n int64, width int) string {
	s := strconv.FormatInt(n, 10)
	for len(s) < width {
		s = "0" + s
	}
	return s
}
