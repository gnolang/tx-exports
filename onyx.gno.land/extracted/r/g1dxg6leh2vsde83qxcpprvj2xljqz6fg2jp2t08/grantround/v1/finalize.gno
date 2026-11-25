package grantround

import (
	"chain"
	"chain/banker"
	"chain/runtime"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
)

type transfer struct {
	to     address
	amount int64
}

// Finalize settles a round; anyone may call it once a terminal condition holds.
//
//   - No rule by HRule, or no reveal by HReveal: cancelled; the grant returns to
//     the customer and every bond to its sponsor.
//   - After HSheetReveal: each joined evaluator without a revealed sheet (a
//     commitment left closed included) loses Slash to the customer and gets
//     Bond-Slash back to the sponsor; the others get Bond back. The winner is
//     computed from the revealed sheets by the adopted rule and paid the grant
//     once; with no winner (quorum not met, or a tie under "refund") the grant returns to the
//     customer.
//
// The round is marked finalized before any coins move, so a second call aborts.
func Finalize(cur realm, roundID int) {
	r := mustGet(roundID)
	if r.Finalized {
		panic("grantround: round already finalized")
	}
	h := runtime.ChainHeight()
	cancel := (r.Rule == nil && h > r.HRule) || (r.Rule != nil && r.Apps == nil && h > r.HReveal)
	settle := r.Apps != nil && h > r.HSheetReveal
	if !cancel && !settle {
		panic("grantround: round cannot be finalized yet")
	}
	r.Finalized = true

	var out []transfer
	if cancel {
		r.Cancelled = true
		out = append(out, transfer{r.Customer, r.Grant})
		for _, s := range r.Sponsors {
			if s != "" {
				out = append(out, transfer{s, r.Bond})
			}
		}
	} else {
		var sheets []rulecalc.Sheet
		for i, s := range r.Sponsors {
			if s == "" {
				continue
			}
			if r.Sheets[i] != nil {
				sheets = append(sheets, *r.Sheets[i])
				out = append(out, transfer{s, r.Bond})
			} else {
				out = append(out, transfer{r.Customer, r.Slash}, transfer{s, r.Bond - r.Slash})
			}
		}
		r.Winner, r.Paid = rulecalc.Compute(*r.Rule, len(r.Apps), sheets)
		recordTracks(r)
		if r.Paid {
			out = append(out, transfer{r.Apps[r.Winner].Payout, r.Grant})
		} else {
			out = append(out, transfer{r.Customer, r.Grant})
		}
	}

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	for _, tr := range out {
		if tr.amount > 0 {
			b.SendCoins(cur.Address(), tr.to, chain.Coins{{"ugnot", tr.amount}})
		}
	}
}
