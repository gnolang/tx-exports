package tollgate

import (
	"chain/runtime"
	"strconv"
	"strings"

	ptollgate "gno.land/p/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/tollgate"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

const realmBaseLink = "/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/tollgate/v2"

func rlink(sub string) string {
	if sub == "" {
		return realmBaseLink
	}
	return realmBaseLink + ":" + sub
}

func actionLink(fn string, params string) string {
	if params == "" {
		return realmBaseLink + "$help&func=" + fn
	}
	return realmBaseLink + "$help&func=" + fn + "&" + params
}

// jsonEscape produces strict RFC 8259 JSON and unicode-escapes Markdown
// metacharacters so :json/* routes cannot inject active Markdown in gnoweb.
func jsonEscape(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '[', ']', '<', '>', '*', '_', '|', '#', '!', '`':
			b.WriteString(`\u00`)
			const hexDigits = "0123456789abcdef"
			b.WriteByte(hexDigits[c>>4])
			b.WriteByte(hexDigits[c&0x0f])
		default:
			if c < 0x20 {
				b.WriteString(" ")
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderHome()
	}

	parts := strings.Split(path, "/")
	switch parts[0] {
	case "services":
		return renderServices()
	case "service":
		if len(parts) == 2 {
			return renderServiceDetail(parts[1])
		}
	case "passes":
		return renderPasses()
	case "pass":
		if len(parts) == 2 {
			return renderPassDetail(parts[1])
		}
	case "subs":
		return renderSubs()
	case "sub":
		if len(parts) == 2 {
			return renderSubDetail(parts[1])
		}
	case "receipt":
		if len(parts) == 2 {
			return renderReceiptDetail(parts[1])
		}
	case "disputes":
		return renderDisputes()
	case "json":
		return renderJSON(parts[1:])
	}

	return "# Tollgate — Not Found\n\nUnknown route " + sanitize.InlineCode(path) + ".\n\n[Back to Tollgate Home](" + rlink("") + ")\n"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Tollgate — On-Chain x402 Metering & Receipt Protocol\n\n")
	b.WriteString("> Bridging `gnolang/x402` HTTP 402 micropayments with PayWord SHA-256 hash-chain authenticated prepaid credit vaults, fixed-window subscriptions, challenge-window settlements, and verifiable SHA-256 receipts on Gno.land.\n\n")

	b.WriteString("## Quick Actions\n\n")
	b.WriteString("- [**Register a Service**](" + actionLink("RegisterService", "") + ") · ")
	b.WriteString("[**Open a Credit Pass**](" + actionLink("OpenPass", "") + ") · ")
	b.WriteString("[**Subscribe to a Service**](" + actionLink("Subscribe", "") + ")\n\n")

	b.WriteString("## Live Protocol Telemetry\n\n")
	b.WriteString("| Metric | Value |\n|---|---|\n")
	b.WriteString(ufmt.Sprintf("| Chain ID | `%s` |\n", runtime.ChainID()))
	b.WriteString(ufmt.Sprintf("| Block Height | `%d` |\n", runtime.ChainHeight()))
	b.WriteString(ufmt.Sprintf("| Live Vault TVL (`GetCoin`) | `%d ugnot` |\n", VaultBalanceUgnot()))
	b.WriteString(ufmt.Sprintf("| Registered Services | `%d` |\n", services.Size()))
	b.WriteString(ufmt.Sprintf("| Active / Total Passes | `%d / %d` |\n", activePassesCount, passes.Size()))
	b.WriteString(ufmt.Sprintf("| Subscriptions | `%d` |\n", subs.Size()))
	b.WriteString(ufmt.Sprintf("| Receipts Anchored | `%d` |\n", receipts.Size()))
	b.WriteString(ufmt.Sprintf("| Total Pass Deposits (Escrowed) | `%d ugnot` |\n", totalDepositedUgnot))
	b.WriteString(ufmt.Sprintf("| Total Pass Settlements (Escrowed) | `%d ugnot` |\n", totalSettledUgnot))
	b.WriteString(ufmt.Sprintf("| Total Subscriptions (On-Chain) | `%d ugnot` |\n", totalSubRevenueUgnot))
	b.WriteString(ufmt.Sprintf("| Total Pass Refunds | `%d ugnot` |\n", totalRefundedUgnot))
	b.WriteString(ufmt.Sprintf("| External x402 Anchored _(provider-attested)_ | `%d ugnot` |\n\n", totalX402AnchoredUgnot))

	b.WriteString("## Registered Services\n\n")
	if services.Size() == 0 {
		b.WriteString("_No services registered yet._\n\n")
	} else {
		b.WriteString("| ID | Slug | Name | Unit Price | Sub Plan | Calls | On-Chain Rev | x402 Attested | Status |\n|---|---|---|---|---|---|---|---|---|\n")
		services.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
			s := v.(*serviceRecord)
			status := StatusActive
			if s.paused {
				status = StatusPaused
			}
			subStr := "—"
			if s.subPriceUgnot > 0 {
				subStr = ufmt.Sprintf("%d ugnot / %d calls", s.subPriceUgnot, s.subQuota)
			}
			b.WriteString(ufmt.Sprintf(
				"| [%d](%s) | `%s` | %s | `%d ugnot` | %s | `%d` | `%d ugnot` | `%d ugnot` | `%s` |\n",
				s.id,
				rlink("service/"+strconv.FormatUint(s.id, 10)),
				s.slug,
				sanitize.TableCell(s.name),
				s.unitPriceUgnot,
				subStr,
				s.totalCalls,
				s.escrowedRevenue,
				s.x402AttestedRevenue,
				status,
			))
			return false
		})
		b.WriteString("\n")
	}

	b.WriteString("## Recent Receipts\n\n")
	if receipts.Size() == 0 {
		b.WriteString("_No receipts anchored yet._\n\n")
	} else {
		b.WriteString("| ID | Rail | Status | Service | Units | Amount | Ed25519 Signed | Commitment (SHA-256) |\n|---|---|---|---|---|---|---|---|\n")
		receipts.ReverseIterateByOffset(0, 10, func(_ string, v any) bool {
			r := v.(*receiptRecord)
			shortHash := r.commitment[:16] + "..."
			signedStr := "no"
			if r.buyerSigned {
				signedStr = "yes"
			}
			b.WriteString(ufmt.Sprintf(
				"| [%d](%s) | `%s` | `%s` | [#%d](%s) | `%d` | `%d ugnot` | `%s` | `%s` |\n",
				r.id,
				rlink("receipt/"+strconv.FormatUint(r.id, 10)),
				r.rail,
				receiptSettlementStatus(r),
				r.serviceID,
				rlink("service/"+strconv.FormatUint(r.serviceID, 10)),
				r.units, r.amountUgnot, signedStr, shortHash,
			))
			return false
		})
		b.WriteString("\n")
	}

	b.WriteString("## Explorer Navigation\n\n")
	b.WriteString("- [All Services](" + rlink("services") + ")\n")
	b.WriteString("- [Credit Passes](" + rlink("passes") + ")\n")
	b.WriteString("- [Subscriptions](" + rlink("subs") + ")\n")
	b.WriteString("- [Settlement & Dispute Monitor](" + rlink("disputes") + ")\n")
	b.WriteString("- Machine JSON: `:json/summary`, `:json/services`, `:json/service/<id>`, `:json/pass/<id>`, `:json/sub/<id>`, `:json/receipt/<id>`\n")
	return b.String()
}

func renderServices() string {
	var b strings.Builder
	b.WriteString("# Tollgate — Service Directory\n\n")
	b.WriteString("[Back to Home](" + rlink("") + ") | [Register Service](" + actionLink("RegisterService", "") + ")\n\n")
	if services.Size() == 0 {
		b.WriteString("_No services registered yet._\n")
		return b.String()
	}
	b.WriteString("| ID | Slug | Name | Endpoint | Unit Price | Challenge | On-Chain Rev | x402 Attested |\n|---|---|---|---|---|---|---|---|\n")
	services.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
		s := v.(*serviceRecord)
		b.WriteString(ufmt.Sprintf(
			"| [%d](%s) | `%s` | %s | %s | `%d ugnot` | `%d blk` | `%d ugnot` | `%d ugnot` |\n",
			s.id,
			rlink("service/"+strconv.FormatUint(s.id, 10)),
			s.slug,
			sanitize.TableCell(s.name),
			sanitize.TableCell(s.endpointURL),
			s.unitPriceUgnot,
			s.challengeBlocks,
			s.escrowedRevenue,
			s.x402AttestedRevenue,
		))
		return false
	})
	return b.String()
}

func renderPasses() string {
	var b strings.Builder
	b.WriteString("# Tollgate — Prepaid Credit Passes\n\n")
	b.WriteString("[Back to Home](" + rlink("") + ") | [Open Pass](" + actionLink("OpenPass", "") + ")\n\n")
	if passes.Size() == 0 {
		b.WriteString("_No passes opened yet._\n")
		return b.String()
	}
	b.WriteString("| ID | Service | Buyer | Deposit | Spent | Pending | Available | Ed25519 Auth | Expiry | Status |\n|---|---|---|---|---|---|---|---|---|---|\n")
	passes.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
		p := v.(*passRecord)
		avail, _ := ptollgate.ComputeAvailable(p.depositUgnot, p.spentUgnot, p.pendingUgnot)
		status := StatusActive
		if p.closed {
			status = StatusClosed
		} else if runtime.ChainHeight() >= p.expiryHeight {
			status = "expired"
		}
		auth := "challenge-only"
		if p.voucherPubKey != "" {
			auth = "payword:" + p.voucherPubKey[:10] + "..."
		}
		b.WriteString(ufmt.Sprintf(
			"| [#%d](%s) | [#%d](%s) | `%s` | `%d` | `%d` | `%d` | `%d` | `%s` | `%d` | `%s` |\n",
			p.id, rlink("pass/"+strconv.FormatUint(p.id, 10)),
			p.serviceID, rlink("service/"+strconv.FormatUint(p.serviceID, 10)),
			p.buyer.String()[:12]+"...",
			p.depositUgnot, p.spentUgnot, p.pendingUgnot, avail, auth, p.expiryHeight, status,
		))
		return false
	})
	return b.String()
}

func renderSubs() string {
	var b strings.Builder
	b.WriteString("# Tollgate — Subscriptions\n\n")
	b.WriteString("[Back to Home](" + rlink("") + ") | [Subscribe](" + actionLink("Subscribe", "") + ")\n\n")
	if subs.Size() == 0 {
		b.WriteString("_No subscriptions minted yet._\n")
		return b.String()
	}
	b.WriteString("| ID | Service | Buyer | Paid | Quota Used / Total | Expiry | Status |\n|---|---|---|---|---|---|---|\n")
	subs.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
		s := v.(*subRecord)
		state := "expired"
		if runtime.ChainHeight() <= s.expiryHeight && s.quotaUsed < s.quotaTotal {
			state = StatusActive
		}
		b.WriteString(ufmt.Sprintf(
			"| [#%d](%s) | [#%d](%s) | `%s` | `%d ugnot` | `%d / %d` | `%d` | `%s` |\n",
			s.id, rlink("sub/"+strconv.FormatUint(s.id, 10)),
			s.serviceID, rlink("service/"+strconv.FormatUint(s.serviceID, 10)),
			s.buyer.String()[:12]+"...",
			s.paidUgnot, s.quotaUsed, s.quotaTotal, s.expiryHeight, state,
		))
		return false
	})
	return b.String()
}

func renderServiceDetail(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		if v := slugIndex.Get(rawID); v != nil {
			id = v.(uint64)
		}
	}
	svc := getServiceRecord(id)
	if svc == nil {
		return "# Service Not Found\n\nNo service matches " + sanitize.InlineCode(rawID) + ".\n\n[Back to Home](" + rlink("") + ")\n"
	}

	memoExample, _ := ptollgate.FormatInvoiceMemo(svc.id, "req-0001")
	status := StatusActive
	if svc.paused {
		status = StatusPaused
	}
	idStr := strconv.FormatUint(svc.id, 10)

	var b strings.Builder
	b.WriteString("# Service #" + idStr + ": " + sanitize.InlineText(svc.name) + "\n\n")
	b.WriteString("[Back to Home](" + rlink("") + ") | [All Services](" + rlink("services") + ") | ")
	b.WriteString("[**Open Pass**](" + actionLink("OpenPass", "serviceID="+idStr) + ") | ")
	b.WriteString("[**Subscribe**](" + actionLink("Subscribe", "serviceID="+idStr) + ")\n\n")
	if svc.description != "" {
		b.WriteString(sanitize.Block(svc.description))
	}
	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Slug | `" + svc.slug + "` |\n")
	b.WriteString("| Status | `" + status + "` |\n")
	b.WriteString("| Owner | `" + svc.owner.String() + "` |\n")
	b.WriteString("| PayTo | `" + svc.payTo.String() + "` |\n")
	b.WriteString("| Endpoint | " + sanitize.TableCell(svc.endpointURL) + " |\n")
	b.WriteString(ufmt.Sprintf("| Unit Price | `%d ugnot` (volume discounts up to 20%%) |\n", svc.unitPriceUgnot))
	b.WriteString(ufmt.Sprintf("| Subscription | `%d ugnot` for `%d` calls / `%d` blocks |\n", svc.subPriceUgnot, svc.subQuota, svc.subBlocks))
	b.WriteString(ufmt.Sprintf("| Challenge Window | `%d` blocks |\n", svc.challengeBlocks))
	b.WriteString(ufmt.Sprintf("| Total Metered Calls | `%d` |\n", svc.totalCalls))
	b.WriteString(ufmt.Sprintf("| On-Chain Revenue (settled passes + subscriptions) | `%d ugnot` |\n", svc.escrowedRevenue))
	b.WriteString(ufmt.Sprintf("| External x402 Revenue _(provider-attested)_ | `%d ugnot` |\n", svc.x402AttestedRevenue))
	b.WriteString("| x402 Invoice Memo | `" + memoExample + "` |\n")
	return b.String()
}

func renderPassDetail(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		return "# Pass Not Found\n\nInvalid pass ID " + sanitize.InlineCode(rawID) + ".\n\n[Back to Home](" + rlink("") + ")\n"
	}
	p, ok := GetPass(id)
	if !ok {
		return "# Pass Not Found\n\nPass " + sanitize.InlineCode(rawID) + " does not exist.\n\n[Back to Home](" + rlink("") + ")\n"
	}
	status := StatusActive
	if p.Closed {
		status = StatusClosed
	} else if runtime.ChainHeight() >= p.ExpiryHeight {
		status = "expired"
	}
	sessLabel := "master-key"
	if p.UsedSessionKey {
		sessLabel = "session-key (" + p.SessionKeyAddr.String() + ")"
	}
	idStr := strconv.FormatUint(p.ID, 10)
	svcStr := strconv.FormatUint(p.ServiceID, 10)

	var b strings.Builder
	b.WriteString("# Credit Pass #" + idStr + "\n\n")
	b.WriteString("[Back to Home](" + rlink("") + ") | [Service #" + svcStr + "](" + rlink("service/"+svcStr) + ") | ")
	b.WriteString("[**TopUpPass**](" + actionLink("TopUpPass", "passID="+idStr) + ") | ")
	b.WriteString("[**RequestEarlyClose**](" + actionLink("RequestEarlyClose", "passID="+idStr) + ") | ")
	b.WriteString("[**ClosePass**](" + actionLink("ClosePass", "passID="+idStr) + ")\n\n")

	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Status | `" + status + "` |\n")
	b.WriteString("| Buyer | `" + p.Buyer.String() + "` |\n")
	b.WriteString("| Signer Mode | `" + sessLabel + "` |\n")
	if p.VoucherPubKey != "" {
		b.WriteString("| Ed25519 Voucher Key | `" + p.VoucherPubKey + "` (enforced on-chain & in gateway) |\n")
	} else {
		b.WriteString("| Ed25519 Voucher Key | _none (protected by challenge window)_ |\n")
	}
	b.WriteString(ufmt.Sprintf("| Deposited | `%d ugnot` |\n", p.DepositUgnot))
	b.WriteString(ufmt.Sprintf("| Spent | `%d ugnot` |\n", p.SpentUgnot))
	b.WriteString(ufmt.Sprintf("| Pending Escrow | `%d ugnot` |\n", p.PendingUgnot))
	b.WriteString(ufmt.Sprintf("| Available | `%d ugnot` |\n", p.AvailableUgnot))
	b.WriteString(ufmt.Sprintf("| Max Per Call | `%d ugnot` |\n", p.MaxPerCallUgnot))
	b.WriteString(ufmt.Sprintf("| Expiry Height | `%d` (current: `%d`) |\n", p.ExpiryHeight, runtime.ChainHeight()))
	b.WriteString(ufmt.Sprintf("| Settled Calls | `%d` |\n", p.SettledCalls))
	return b.String()
}

func renderSubDetail(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		return "# Subscription Not Found\n\n[Back to Home](" + rlink("") + ")\n"
	}
	s, ok := GetSubscription(id)
	if !ok {
		return "# Subscription Not Found\n\n[Back to Home](" + rlink("") + ")\n"
	}
	state := "expired"
	if s.Active {
		state = StatusActive
	}
	svcStr := strconv.FormatUint(s.ServiceID, 10)
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Subscription #%d\n\n[Back to Home](%s) | [Service #%d](%s)\n\n", s.ID, rlink(""), s.ServiceID, rlink("service/"+svcStr)))
	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Status | `" + state + "` |\n")
	b.WriteString("| Buyer | `" + s.Buyer.String() + "` |\n")
	if s.VoucherPubKey != "" {
		b.WriteString("| Ed25519 Voucher Key | `" + s.VoucherPubKey + "` |\n")
	}
	b.WriteString(ufmt.Sprintf("| Paid | `%d ugnot` |\n", s.PaidUgnot))
	b.WriteString(ufmt.Sprintf("| Quota | `%d / %d` (`%d` remaining) |\n", s.QuotaUsed, s.QuotaTotal, s.QuotaRemaining))
	b.WriteString(ufmt.Sprintf("| Window | block `%d` -> `%d` (current: `%d`) |\n", s.StartHeight, s.ExpiryHeight, runtime.ChainHeight()))
	return b.String()
}

func renderReceiptDetail(rawID string) string {
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		if v := receiptHashIndex.Get(rawID); v != nil {
			id = v.(uint64)
		} else {
			return "# Receipt Not Found\n\nUnknown receipt " + sanitize.InlineCode(rawID) + ".\n\n[Back to Home](" + rlink("") + ")\n"
		}
	}
	r, ok := GetReceipt(id)
	if !ok {
		return "# Receipt Not Found\n\n[Back to Home](" + rlink("") + ")\n"
	}
	svcStr := strconv.FormatUint(r.ServiceID, 10)
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Receipt #%d\n\n[Back to Home](%s) | [Service #%d](%s)\n\n", r.ID, rlink(""), r.ServiceID, rlink("service/"+svcStr)))
	if r.SettlementStatus == StatusRefunded {
		b.WriteString("> **INVALIDATED / REFUNDED:** The settlement backing this receipt was refunded or reclaimed by the buyer.\n\n")
	}
	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Payment Rail | `" + r.Rail + "` |\n")
	b.WriteString("| Settlement Status | `" + r.SettlementStatus + "` |\n")
	b.WriteString(ufmt.Sprintf("| Buyer Ed25519 Signed | `%t` |\n", r.BuyerSigned))
	b.WriteString(ufmt.Sprintf("| Service ID | `%d` |\n", r.ServiceID))
	b.WriteString(ufmt.Sprintf("| Pass ID | `%d` |\n", r.PassID))
	b.WriteString(ufmt.Sprintf("| Subscription ID | `%d` |\n", r.SubID))
	b.WriteString(ufmt.Sprintf("| Settlement ID | `%d` |\n", r.SettlementID))
	b.WriteString("| Buyer | `" + r.Buyer.String() + "` |\n")
	b.WriteString("| Provider | `" + r.Provider.String() + "` |\n")
	b.WriteString(ufmt.Sprintf("| Units | `%d` |\n", r.Units))
	b.WriteString(ufmt.Sprintf("| Amount | `%d ugnot` |\n", r.AmountUgnot))
	b.WriteString("| Nonce | `" + r.Nonce + "` |\n")
	b.WriteString("| Resource Hash | `" + r.ResourceHash + "` |\n")
	b.WriteString("| SHA-256 Commitment | `" + r.Commitment + "` |\n")
	if r.TxHash != "" {
		b.WriteString("| x402 Tx Hash | " + sanitize.InlineCode(r.TxHash) + " |\n")
	}
	b.WriteString(ufmt.Sprintf("| Anchored Height | `%d` |\n", r.Height))
	return b.String()
}

func renderDisputes() string {
	var b strings.Builder
	b.WriteString("# Tollgate — Settlements & Challenge Window Monitor\n\n[Back to Home](" + rlink("") + ")\n\n")
	if settlements.Size() == 0 {
		b.WriteString("_No metered settlements submitted yet._\n")
		return b.String()
	}
	b.WriteString("| ID | Pass | Units | Net | Discount | Ed25519 | Challenge End | Status | Action | Reason |\n|---|---|---|---|---|---|---|---|---|---|\n")
	settlements.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
		st := v.(*settlementRecord)
		reason := "—"
		if st.disputeReason != "" {
			reason = sanitize.TableCell(st.disputeReason)
		}
		stStr := strconv.FormatUint(st.id, 10)
		act := "—"
		if st.status == StatusPending {
			act = "[Dispute](" + actionLink("DisputeSettlement", "settlementID="+stStr) + ")"
		} else if st.status == StatusDisputed {
			act = "[Reclaim](" + actionLink("ReclaimDisputedSettlement", "settlementID="+stStr) + ")"
		}
		b.WriteString(ufmt.Sprintf(
			"| `%d` | [#%d](%s) | `%d` | `%d ugnot` | `%d bps` | `%t` | `%d` | `%s` | %s | %s |\n",
			st.id, st.passID, rlink("pass/"+strconv.FormatUint(st.passID, 10)),
			st.units, st.netUgnot, st.discountBps, st.buyerSigned, st.challengeEnd, st.status, act, reason,
		))
		return false
	})
	return b.String()
}

func renderJSON(parts []string) string {
	if len(parts) == 0 || parts[0] == "summary" {
		return ufmt.Sprintf(
			`{"protocol":%s,"chainId":%s,"height":%d,"vaultBalanceUgnot":%d,"services":%d,"activePasses":%d,"passes":%d,"subscriptions":%d,"settlements":%d,"receipts":%d,"totalDepositedUgnot":%d,"totalSettledUgnot":%d,"totalX402AnchoredUgnot":%d,"totalSubRevenueUgnot":%d,"totalRefundedUgnot":%d}`,
			jsonEscape(ptollgate.ProtocolVersion),
			jsonEscape(runtime.ChainID()),
			runtime.ChainHeight(),
			VaultBalanceUgnot(),
			services.Size(),
			activePassesCount,
			passes.Size(),
			subs.Size(),
			settlements.Size(),
			receipts.Size(),
			totalDepositedUgnot,
			totalSettledUgnot,
			totalX402AnchoredUgnot,
			totalSubRevenueUgnot,
			totalRefundedUgnot,
		)
	}
	if parts[0] == "services" {
		var b strings.Builder
		b.WriteByte('[')
		first := true
		services.ReverseIterateByOffset(0, maxRenderRows, func(_ string, v any) bool {
			if !first {
				b.WriteByte(',')
			}
			first = false
			b.WriteString(serviceJSON(v.(*serviceRecord)))
			return false
		})
		b.WriteByte(']')
		return b.String()
	}
	if len(parts) == 2 {
		id, err := strconv.ParseUint(parts[1], 10, 64)
		switch parts[0] {
		case "service":
			if err != nil {
				if v := slugIndex.Get(parts[1]); v != nil {
					id = v.(uint64)
				}
			}
			if s := getServiceRecord(id); s != nil {
				return serviceJSON(s)
			}
		case "pass":
			if err == nil {
				if p, ok := GetPass(id); ok {
					return ufmt.Sprintf(
						`{"id":%d,"serviceId":%d,"buyer":%s,"depositUgnot":%d,"spentUgnot":%d,"pendingUgnot":%d,"availableUgnot":%d,"maxPerCallUgnot":%d,"expiryHeight":%d,"openedHeight":%d,"closed":%t,"usedSessionKey":%t,"voucherPubKey":%s,"settledCalls":%d,"currentHeight":%d}`,
						p.ID, p.ServiceID, jsonEscape(p.Buyer.String()), p.DepositUgnot, p.SpentUgnot, p.PendingUgnot,
						p.AvailableUgnot, p.MaxPerCallUgnot, p.ExpiryHeight, p.OpenedHeight, p.Closed,
						p.UsedSessionKey, jsonEscape(p.VoucherPubKey), p.SettledCalls, runtime.ChainHeight(),
					)
				}
			}
		case "sub":
			if err == nil {
				if s, ok := GetSubscription(id); ok {
					return ufmt.Sprintf(
						`{"id":%d,"serviceId":%d,"buyer":%s,"paidUgnot":%d,"quotaTotal":%d,"quotaUsed":%d,"quotaRemaining":%d,"startHeight":%d,"expiryHeight":%d,"active":%t,"voucherPubKey":%s,"currentHeight":%d}`,
						s.ID, s.ServiceID, jsonEscape(s.Buyer.String()), s.PaidUgnot, s.QuotaTotal,
						s.QuotaUsed, s.QuotaRemaining, s.StartHeight, s.ExpiryHeight, s.Active,
						jsonEscape(s.VoucherPubKey), runtime.ChainHeight(),
					)
				}
			}
		case "receipt":
			if err != nil {
				if v := receiptHashIndex.Get(parts[1]); v != nil {
					id = v.(uint64)
				}
			}
			if r, ok := GetReceipt(id); ok {
				return ufmt.Sprintf(
					`{"id":%d,"rail":%s,"serviceId":%d,"passId":%d,"subId":%d,"settlementId":%d,"settlementStatus":%s,"buyer":%s,"provider":%s,"units":%d,"amountUgnot":%d,"nonce":%s,"resourceHash":%s,"commitment":%s,"txHash":%s,"height":%d,"buyerSigned":%t}`,
					r.ID, jsonEscape(r.Rail), r.ServiceID, r.PassID, r.SubID, r.SettlementID,
					jsonEscape(r.SettlementStatus), jsonEscape(r.Buyer.String()),
					jsonEscape(r.Provider.String()), r.Units, r.AmountUgnot, jsonEscape(r.Nonce),
					jsonEscape(r.ResourceHash), jsonEscape(r.Commitment), jsonEscape(r.TxHash), r.Height, r.BuyerSigned,
				)
			}
		case "settlement":
			if err == nil {
				if st, ok := GetSettlement(id); ok {
					return ufmt.Sprintf(
						`{"id":%d,"serviceId":%d,"passId":%d,"buyer":%s,"provider":%s,"units":%d,"grossUgnot":%d,"discountBps":%d,"netUgnot":%d,"nonce":%s,"resourceHash":%s,"commitment":%s,"claimedHeight":%d,"challengeEnd":%d,"status":%s,"disputeReason":%s,"receiptId":%d,"buyerSigned":%t}`,
						st.ID, st.ServiceID, st.PassID, jsonEscape(st.Buyer.String()), jsonEscape(st.Provider.String()),
						st.Units, st.GrossUgnot, st.DiscountBps, st.NetUgnot, jsonEscape(st.Nonce),
						jsonEscape(st.ResourceHash), jsonEscape(st.Commitment), st.ClaimedHeight,
						st.ChallengeEnd, jsonEscape(st.Status), jsonEscape(st.DisputeReason), st.ReceiptID, st.BuyerSigned,
					)
				}
			}
		}
	}
	return `{"error":"not_found"}`
}

func serviceJSON(s *serviceRecord) string {
	return ufmt.Sprintf(
		`{"id":%d,"slug":%s,"name":%s,"description":%s,"endpointUrl":%s,"owner":%s,"payTo":%s,"unitPriceUgnot":%d,"subPriceUgnot":%d,"subBlocks":%d,"subQuota":%d,"challengeBlocks":%d,"paused":%t,"createdHeight":%d,"totalCalls":%d,"escrowedRevenue":%d,"x402AttestedRevenue":%d}`,
		s.id, jsonEscape(s.slug), jsonEscape(s.name), jsonEscape(s.description), jsonEscape(s.endpointURL),
		jsonEscape(s.owner.String()), jsonEscape(s.payTo.String()), s.unitPriceUgnot, s.subPriceUgnot,
		s.subBlocks, s.subQuota, s.challengeBlocks, s.paused, s.createdHeight, s.totalCalls,
		s.escrowedRevenue, s.x402AttestedRevenue,
	)
}
