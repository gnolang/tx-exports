package whisper

import (
	"strconv"
	"strings"

	"gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance"
)

// Render serves the gnoweb explorer for Arobi Whisper on Gno.land.
//
// Routes:
//   /                      Directory, global RFC 6962 commitment root, escrow stats
//   /u/<handle-or-addr>    Public X25519 keycard & inbox policy
//   /inbox/<handle-or-addr> Public encrypted envelopes & commitments (zero plaintext)
//   /escrow/<id>           DeFi conditional escrow status & settlement audit
func Render(path string) string {
	clean := strings.Trim(path, "/")
	if clean == "" {
		return renderHome()
	}
	if strings.HasPrefix(clean, "u/") {
		return renderUser(strings.TrimPrefix(clean, "u/"))
	}
	if strings.HasPrefix(clean, "inbox/") {
		return renderInbox(strings.TrimPrefix(clean, "inbox/"))
	}
	if strings.HasPrefix(clean, "escrow/") {
		return renderEscrow(strings.TrimPrefix(clean, "escrow/"))
	}
	return "# Not Found\n\nUnknown path `" + clean + "`.\n\n[Back to Arobi Whisper](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Arobi Whisper — End-to-End Encrypted DeFi Chat on Gno.land\n\n")
	b.WriteString("Client-side `X25519 + HKDF-SHA256 + XChaCha20-Poly1305` sealed boxes paired with native GNOT ")
	b.WriteString("tipping, hash-locked DeFi escrows, programmable anti-spam inbox policies, and RFC 6962 ")
	b.WriteString("evidence proofs powered by `gno.land/p/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/assurance`. Plaintext never touches chain state.\n\n")

	b.WriteString("| Metric | Value |\n| --- | --- |\n")
	b.WriteString("| Free Tier | `" + strconv.FormatInt(FreePeriodCredits, 10) + "` credits, `4 KiB` max ciphertext |\n")
	b.WriteString("| Pro Subscription (30 days) | `" + strconv.FormatInt(subscriptionPriceUgnot, 10) + "ugnot` (`" + strconv.FormatInt(ProPeriodCredits, 10) + "` credits, `16 KiB` ciphertext, DeFi HTLC escrows) |\n")
	b.WriteString("| Overage / Escrow Settlement Fee | `" + strconv.FormatInt(overageFeeUgnot, 10) + "ugnot` per overage msg · `" + strconv.FormatInt(escrowFeeBps, 10) + " bps` on claimed escrows |\n")
	b.WriteString("| Registered Identities | " + strconv.Itoa(len(identityOrder)) + " |\n")
	b.WriteString("| Encrypted Messages | " + strconv.Itoa(len(messages)) + " |\n")
	b.WriteString("| DeFi Escrows Created | " + strconv.Itoa(len(escrows)) + " |\n")
	b.WriteString("| Total Direct Tips | `" + strconv.FormatInt(totalTips, 10) + "ugnot` |\n")
	b.WriteString("| Total Escrowed Volume | `" + strconv.FormatInt(totalEscrowed, 10) + "ugnot` |\n")
	b.WriteString("| Evidence Accumulator Leaves | " + strconv.FormatUint(evidenceAcc.Size(), 10) + " |\n")
	b.WriteString("| Global RFC 6962 Root | `" + assurance.Hex(evidenceAcc.Root()) + "` |\n\n")

	b.WriteString("## Public X25519 Key Directory\n\n")
	if len(identityOrder) == 0 {
		b.WriteString("_No identities registered yet. Call `RegisterIdentity` to publish your X25519 public key._\n")
		return b.String()
	}

	b.WriteString("| Handle | Address | Min Tip | Allowlist | Inbox | Keycard |\n")
	b.WriteString("| --- | --- | ---: | --- | ---: | --- |\n")
	for _, addr := range identityOrder {
		id, ok := identities.Get(addr).(*Identity)
		if !ok || id == nil {
			continue
		}
		hLabel := "_none_"
		linkKey := id.Address.String()
		if id.Handle != "" {
			hLabel = "@" + id.Handle
			linkKey = id.Handle
		}
		b.WriteString("| " + hLabel + " | `" + id.Address.String() + "` | `" +
			strconv.FormatInt(id.MinTipUgnot, 10) + "ugnot` | `" +
			strconv.FormatBool(id.AllowListOnly) + "` | " +
			"[View (" + strconv.Itoa(len(id.InboxIDs)) + ")](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper:inbox/" + linkKey + ") | " +
			"[Keycard](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper:u/" + linkKey + ") |\n")
	}
	return b.String()
}

func renderUser(q string) string {
	id, ok := tryResolveIdentity(q)
	if !ok {
		return "# Identity Not Found\n\nNo Whisper identity for `" + q + "`.\n\n[Back](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)"
	}
	var b strings.Builder
	title := id.Address.String()
	if id.Handle != "" {
		title = "@" + id.Handle + " (`" + id.Address.String() + "`)"
	}
	b.WriteString("# Whisper Keycard: " + title + "\n\n")
	if id.DisplayName != "" {
		b.WriteString("- **Display Name:** " + id.DisplayName + "\n")
	}
	b.WriteString("- **X25519 Encryption Public Key:** `" + id.EncPubHex + "`\n")
	if id.SignPubHex != "" {
		b.WriteString("- **Ed25519 Signing Public Key:** `" + id.SignPubHex + "`\n")
	}
	b.WriteString("- **Minimum Anti-Spam Tip:** `" + strconv.FormatInt(id.MinTipUgnot, 10) + "ugnot`\n")
	b.WriteString("- **Allowlist Only:** `" + strconv.FormatBool(id.AllowListOnly) + "`\n")
	b.WriteString("- **Messages Received:** `" + strconv.Itoa(len(id.InboxIDs)) + "` | **Sent:** `" + strconv.Itoa(len(id.SentIDs)) + "`\n\n")
	linkKey := id.Address.String()
	if id.Handle != "" {
		linkKey = id.Handle
	}
	b.WriteString("[Inspect Encrypted Inbox](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper:inbox/" + linkKey + ") · [Back to Directory](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)\n")
	return b.String()
}

func renderInbox(q string) string {
	id, ok := tryResolveIdentity(q)
	if !ok {
		return "# Inbox Not Found\n\nNo Whisper inbox for `" + q + "`.\n\n[Back](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)"
	}
	var b strings.Builder
	b.WriteString("# Encrypted Inbox: `" + id.Address.String() + "`\n\n")
	b.WriteString("_All payloads below are client-sealed `XChaCha20-Poly1305` ciphertexts. Only the holder of the matching local X25519 secret key can decrypt them._\n\n")
	if len(id.InboxIDs) == 0 {
		b.WriteString("_Inbox is empty._\n\n[Back](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)")
		return b.String()
	}
	start := 0
	if len(id.InboxIDs) > 20 {
		start = len(id.InboxIDs) - 20
	}
	for i := len(id.InboxIDs) - 1; i >= start; i-- {
		env := messages[id.InboxIDs[i]-1]
		b.WriteString("- **Msg #" + strconv.FormatUint(env.ID, 10) + "** from `" + env.From +
			"` at height `" + strconv.FormatInt(env.Height, 10) + "` | commitment `" +
			env.CommitmentHex[:16] + "...` | tip `" + strconv.FormatInt(env.TipUgnot, 10) + "ugnot`")
		if env.EscrowID > 0 {
			eid := strconv.FormatUint(env.EscrowID, 10)
			b.WriteString(" | [Escrow #" + eid + "](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper:escrow/" + eid + ")")
		}
		b.WriteString("\n")
	}
	b.WriteString("\n[Back to Directory](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)\n")
	return b.String()
}

func renderEscrow(idStr string) string {
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil || id == 0 || id > uint64(len(escrows)) {
		return "# Escrow Not Found\n\nInvalid escrow id `" + idStr + "`.\n\n[Back](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)"
	}
	e := escrows[id-1]
	var b strings.Builder
	b.WriteString("# Whisper DeFi Escrow #" + idStr + "\n\n")
	b.WriteString("- **Status:** `" + string(e.Status) + "`\n")
	b.WriteString("- **Linked Encrypted Message:** `#" + strconv.FormatUint(e.MessageID, 10) + "`\n")
	b.WriteString("- **Sender:** `" + e.Sender + "`\n")
	b.WriteString("- **Recipient:** `" + e.Recipient + "`\n")
	b.WriteString("- **Locked Amount:** `" + strconv.FormatInt(e.AmountUgnot, 10) + "ugnot`\n")
	if e.HashLockHex != "" {
		b.WriteString("- **HTLC Hashlock (SHA-256):** `" + e.HashLockHex + "`\n")
	} else {
		b.WriteString("- **HTLC Hashlock:** _none (recipient direct claim)_\n")
	}
	b.WriteString("- **Expiry Height:** `" + strconv.FormatInt(e.ExpiryHeight, 10) + "`\n")
	if e.SettledHeight > 0 {
		b.WriteString("- **Settled Height:** `" + strconv.FormatInt(e.SettledHeight, 10) + "`\n")
	}
	b.WriteString("\n[Back to Directory](/r/g1jdc6h96he7wf7xfycu6u7wqhv5j762qtxu5k5t/whisper)\n")
	return b.String()
}

func tryResolveIdentity(q string) (*Identity, bool) {
	trim := strings.TrimSpace(q)
	if id, ok := identities.Get(trim).(*Identity); ok && id != nil {
		return id, true
	}
	clean := strings.ToLower(strings.TrimLeft(trim, "@"))
	if addr, ok := handles.Get(clean).(string); ok && addr != "" {
		if id, ok2 := identities.Get(addr).(*Identity); ok2 && id != nil {
			return id, true
		}
	}
	return nil, false
}
