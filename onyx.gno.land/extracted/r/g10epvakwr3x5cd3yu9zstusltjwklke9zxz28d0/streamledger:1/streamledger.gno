// Package streamledger implements StreamLedger — a trustless, zero-dust
// native ugnot vesting and payment-stream escrow realm for Gno.land.
package streamledger

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math/overflow"
	"strconv"
	"strings"

	"gno.land/p/g10epvakwr3x5cd3yu9zstusltjwklke9zxz28d0/streammath"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	DenomUGNOT      = "ugnot"
	MaxLabelLength  = 120
	StatusActive    = "ACTIVE"
	StatusCompleted = "COMPLETED"
	StatusCancelled = "CANCELLED"

	realmPkgPath = "gno.land/r/g10epvakwr3x5cd3yu9zstusltjwklke9zxz28d0/streamledger"
	realmURLPath = "/r/g10epvakwr3x5cd3yu9zstusltjwklke9zxz28d0/streamledger"
)

// Stream represents a single escrowed ugnot payment/vesting stream.
type Stream struct {
	ID              uint64
	Sender          address
	Recipient       address
	TotalAmount     int64
	Withdrawn       int64
	Refunded        int64
	StartHeight     int64
	CliffHeight     int64
	EndHeight       int64
	CreatedHeight   int64
	CancelledHeight int64
	Cancellable     bool
	Status          string
	Label           string
}

var (
	streams     *avl.Tree // formatIDKey(id) -> *Stream
	bySender    *avl.Tree // "<sender>:<idKey>" -> uint64
	byRecipient *avl.Tree // "<recipient>:<idKey>" -> uint64

	nextStreamID   uint64
	totalDeposited int64
	totalWithdrawn int64
	totalRefunded  int64
	activeCount    int64
	completedCount int64
	cancelledCount int64

	router *mux.Router
)

func init() {
	initState()
	initRouter()
}

func initState() {
	streams = avl.NewTree()
	bySender = avl.NewTree()
	byRecipient = avl.NewTree()
	nextStreamID = 0
	totalDeposited = 0
	totalWithdrawn = 0
	totalRefunded = 0
	activeCount = 0
	completedCount = 0
	cancelledCount = 0
}

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("stream/{id}", renderStreamDetail)
	router.HandleFunc("addr/{address}", renderAddressPortfolio)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write(ufmt.Sprintf("# StreamLedger — Not Found\n\nUnknown path: `%s`\n\n[← Back to Dashboard](%s)\n", req.Path, realmURLPath))
	})
}

// CreateStream locks attached ugnot in escrow and creates a new linear vesting
// stream from the direct EOA caller to recipient.
func CreateStream(
	cur realm,
	recipient address,
	startHeight int64,
	cliffHeight int64,
	endHeight int64,
	cancellable bool,
	label string,
) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("StreamLedger: only direct user call (maketx call) accepted")
	}

	sender := cur.Previous().Address()
	if recipient == "" || !recipient.IsValid() {
		panic("StreamLedger: invalid recipient address")
	}
	if recipient == sender {
		panic("StreamLedger: sender and recipient must differ")
	}

	deposit := requireUGNOTSent()
	if err := streammath.ValidateSchedule(startHeight, cliffHeight, endHeight, deposit); err != nil {
		panic(err.Error())
	}

	cleanLabel := sanitizeLabel(label)
	newTotalDeposited, ok := overflow.Add64(totalDeposited, deposit)
	if !ok {
		panic("StreamLedger: protocol deposit overflow")
	}

	nextStreamID++
	id := nextStreamID
	idKey := formatIDKey(id)

	s := &Stream{
		ID:            id,
		Sender:        sender,
		Recipient:     recipient,
		TotalAmount:   deposit,
		Withdrawn:     0,
		Refunded:      0,
		StartHeight:   startHeight,
		CliffHeight:   cliffHeight,
		EndHeight:     endHeight,
		CreatedHeight: runtime.ChainHeight(),
		Cancellable:   cancellable,
		Status:        StatusActive,
		Label:         cleanLabel,
	}

	streams.Set(idKey, s)
	bySender.Set(indexKey(sender, idKey), id)
	byRecipient.Set(indexKey(recipient, idKey), id)
	totalDeposited = newTotalDeposited
	activeCount++

	chain.Emit(
		"StreamCreated",
		"stream_id", strconv.FormatUint(id, 10),
		"sender", sender.String(),
		"recipient", recipient.String(),
		"amount_ugnot", strconv.FormatInt(deposit, 10),
		"start_height", strconv.FormatInt(startHeight, 10),
		"cliff_height", strconv.FormatInt(cliffHeight, 10),
		"end_height", strconv.FormatInt(endHeight, 10),
		"cancellable", strconv.FormatBool(cancellable),
	)

	return id
}

// Withdraw claims all currently vested, unwithdrawn ugnot for streamID.
// Only the stream's recipient may call Withdraw. Strictly follows CEI.
func Withdraw(cur realm, streamID uint64) int64 {
	caller := cur.Previous().Address()
	s := mustGetStream(streamID)

	if s.Status != StatusActive {
		panic("StreamLedger: stream is not active")
	}
	if caller != s.Recipient {
		panic("StreamLedger: only recipient can withdraw")
	}

	now := runtime.ChainHeight()
	amount := streammath.WithdrawableAmount(
		s.TotalAmount,
		s.Withdrawn,
		s.StartHeight,
		s.CliffHeight,
		s.EndHeight,
		now,
	)
	if amount <= 0 {
		panic("StreamLedger: nothing withdrawable at current height")
	}

	// Effects BEFORE external banker interaction (strict CEI).
	s.Withdrawn += amount
	totalWithdrawn += amount
	if s.Withdrawn >= s.TotalAmount {
		s.Status = StatusCompleted
		activeCount--
		completedCount++
	}

	chain.Emit(
		"StreamWithdrawn",
		"stream_id", strconv.FormatUint(s.ID, 10),
		"recipient", s.Recipient.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
		"total_withdrawn_ugnot", strconv.FormatInt(s.Withdrawn, 10),
		"status", s.Status,
	)

	// Interaction LAST.
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), s.Recipient, chain.NewCoins(chain.NewCoin(DenomUGNOT, amount)))

	return amount
}

// CancelStream cancels an active, cancellable stream. Only the sender may
// cancel. Any vested unwithdrawn balance is sent to the recipient and the
// exact unvested remainder is refunded to the sender (zero dust).
func CancelStream(cur realm, streamID uint64) (int64, int64) {
	caller := cur.Previous().Address()
	s := mustGetStream(streamID)

	if s.Status != StatusActive {
		panic("StreamLedger: stream is not active")
	}
	if !s.Cancellable {
		panic("StreamLedger: stream is non-cancellable")
	}
	if caller != s.Sender {
		panic("StreamLedger: only sender can cancel")
	}

	now := runtime.ChainHeight()
	toRecipient, toSender := streammath.CancelSplit(
		s.TotalAmount,
		s.Withdrawn,
		s.StartHeight,
		s.CliffHeight,
		s.EndHeight,
		now,
	)

	// Effects BEFORE external banker interactions (strict CEI).
	s.Withdrawn += toRecipient
	s.Refunded = toSender
	s.CancelledHeight = now
	s.Status = StatusCancelled

	totalWithdrawn += toRecipient
	totalRefunded += toSender
	activeCount--
	cancelledCount++

	chain.Emit(
		"StreamCancelled",
		"stream_id", strconv.FormatUint(s.ID, 10),
		"sender", s.Sender.String(),
		"recipient", s.Recipient.String(),
		"to_recipient_ugnot", strconv.FormatInt(toRecipient, 10),
		"to_sender_ugnot", strconv.FormatInt(toSender, 10),
		"height", strconv.FormatInt(now, 10),
	)

	// Interactions LAST.
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	if toRecipient > 0 {
		bk.SendCoins(realmAddr, s.Recipient, chain.NewCoins(chain.NewCoin(DenomUGNOT, toRecipient)))
	}
	if toSender > 0 {
		bk.SendCoins(realmAddr, s.Sender, chain.NewCoins(chain.NewCoin(DenomUGNOT, toSender)))
	}

	return toRecipient, toSender
}

// TopUpStream adds attached ugnot to an active stream before its endHeight.
// Only the original sender may top up.
func TopUpStream(cur realm, streamID uint64) {
	if !cur.Previous().IsUserCall() {
		panic("StreamLedger: only direct user call (maketx call) accepted")
	}

	caller := cur.Previous().Address()
	s := mustGetStream(streamID)

	if s.Status != StatusActive {
		panic("StreamLedger: stream is not active")
	}
	if caller != s.Sender {
		panic("StreamLedger: only sender can top up")
	}
	if runtime.ChainHeight() >= s.EndHeight {
		panic("StreamLedger: cannot top up stream at or after end height")
	}

	added := requireUGNOTSent()
	newStreamTotal, ok := overflow.Add64(s.TotalAmount, added)
	if !ok {
		panic("StreamLedger: stream total overflow")
	}
	newProtocolTotal, ok := overflow.Add64(totalDeposited, added)
	if !ok {
		panic("StreamLedger: protocol deposit overflow")
	}

	s.TotalAmount = newStreamTotal
	totalDeposited = newProtocolTotal

	chain.Emit(
		"StreamToppedUp",
		"stream_id", strconv.FormatUint(s.ID, 10),
		"sender", s.Sender.String(),
		"added_ugnot", strconv.FormatInt(added, 10),
		"new_total_ugnot", strconv.FormatInt(s.TotalAmount, 10),
	)
}

// GetStreamJSON returns a deterministic JSON representation of a stream
// evaluated at the live chain height.
func GetStreamJSON(streamID uint64) string {
	s := getStream(streamID)
	if s == nil {
		return `{"error":"stream not found"}`
	}

	now := runtime.ChainHeight()
	vested, withdrawable, remaining, bps := computeLiveMetrics(s, now)

	var b strings.Builder
	b.WriteString("{")
	b.WriteString(`"id":` + strconv.FormatUint(s.ID, 10))
	b.WriteString(`,"sender":"` + escapeJSON(s.Sender.String()) + `"`)
	b.WriteString(`,"recipient":"` + escapeJSON(s.Recipient.String()) + `"`)
	b.WriteString(`,"label":"` + escapeJSON(s.Label) + `"`)
	b.WriteString(`,"status":"` + s.Status + `"`)
	b.WriteString(`,"cancellable":` + strconv.FormatBool(s.Cancellable))
	b.WriteString(`,"totalAmountUgnot":` + strconv.FormatInt(s.TotalAmount, 10))
	b.WriteString(`,"withdrawnUgnot":` + strconv.FormatInt(s.Withdrawn, 10))
	b.WriteString(`,"refundedUgnot":` + strconv.FormatInt(s.Refunded, 10))
	b.WriteString(`,"vestedUgnot":` + strconv.FormatInt(vested, 10))
	b.WriteString(`,"withdrawableUgnot":` + strconv.FormatInt(withdrawable, 10))
	b.WriteString(`,"remainingUgnot":` + strconv.FormatInt(remaining, 10))
	b.WriteString(`,"startHeight":` + strconv.FormatInt(s.StartHeight, 10))
	b.WriteString(`,"cliffHeight":` + strconv.FormatInt(s.CliffHeight, 10))
	b.WriteString(`,"endHeight":` + strconv.FormatInt(s.EndHeight, 10))
	b.WriteString(`,"createdHeight":` + strconv.FormatInt(s.CreatedHeight, 10))
	b.WriteString(`,"cancelledHeight":` + strconv.FormatInt(s.CancelledHeight, 10))
	b.WriteString(`,"currentHeight":` + strconv.FormatInt(now, 10))
	b.WriteString(`,"progressBps":` + strconv.FormatInt(bps, 10))
	b.WriteString("}")
	return b.String()
}

// StatsJSON returns protocol-wide accounting metrics as deterministic JSON.
func StatsJSON() string {
	now := runtime.ChainHeight()
	tvl := totalDeposited - totalWithdrawn - totalRefunded
	escrowBal := banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(realmPkgPath), DenomUGNOT)

	var b strings.Builder
	b.WriteString("{")
	b.WriteString(`"chainHeight":` + strconv.FormatInt(now, 10))
	b.WriteString(`,"totalStreams":` + strconv.FormatUint(nextStreamID, 10))
	b.WriteString(`,"activeStreams":` + strconv.FormatInt(activeCount, 10))
	b.WriteString(`,"completedStreams":` + strconv.FormatInt(completedCount, 10))
	b.WriteString(`,"cancelledStreams":` + strconv.FormatInt(cancelledCount, 10))
	b.WriteString(`,"totalDepositedUgnot":` + strconv.FormatInt(totalDeposited, 10))
	b.WriteString(`,"totalWithdrawnUgnot":` + strconv.FormatInt(totalWithdrawn, 10))
	b.WriteString(`,"totalRefundedUgnot":` + strconv.FormatInt(totalRefunded, 10))
	b.WriteString(`,"tvlUgnot":` + strconv.FormatInt(tvl, 10))
	b.WriteString(`,"escrowBalanceUgnot":` + strconv.FormatInt(escrowBal, 10))
	b.WriteString("}")
	return b.String()
}

// Render serves the interactive gnoweb UI for StreamLedger.
// Supported paths:
//   - ""              : Protocol dashboard & live streams table
//   - "stream/<id>"   : Detailed stream card with one-click txlinks
//   - "addr/<g1...>"  : Outgoing & incoming streams for an address
func Render(path string) string {
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	now := runtime.ChainHeight()
	tvl := totalDeposited - totalWithdrawn - totalRefunded
	createURL := txlink.NewLink("CreateStream").
		AddArgs(
			"recipient", "g1...",
			"startHeight", strconv.FormatInt(now, 10),
			"cliffHeight", strconv.FormatInt(now+10, 10),
			"endHeight", strconv.FormatInt(now+100, 10),
			"cancellable", "true",
			"label", "Contributor Vesting",
		).
		SetSend("1000000ugnot").
		URL()

	var b strings.Builder
	b.WriteString("# StreamLedger\n\n")
	b.WriteString("**Trustless, zero-dust native GNOT vesting & payment streams on Gno.land.**\n\n")
	b.WriteString(ufmt.Sprintf("Live Chain Height: **`#%d`** · [➕ Create New Stream](%s)\n\n", now, createURL))

	b.WriteString("## Protocol Overview\n\n")
	b.WriteString("| Metric | Value |\n")
	b.WriteString("| --- | --- |\n")
	b.WriteString(ufmt.Sprintf("| **Locked TVL** | **%s** (`%d ugnot`) |\n", streammath.FormatUGNOT(tvl), tvl))
	b.WriteString(ufmt.Sprintf("| Total Deposited | %s |\n", streammath.FormatUGNOT(totalDeposited)))
	b.WriteString(ufmt.Sprintf("| Total Withdrawn | %s |\n", streammath.FormatUGNOT(totalWithdrawn)))
	b.WriteString(ufmt.Sprintf("| Total Refunded | %s |\n", streammath.FormatUGNOT(totalRefunded)))
	b.WriteString(ufmt.Sprintf("| Streams | %d total (%d active · %d completed · %d cancelled) |\n\n",
		nextStreamID, activeCount, completedCount, cancelledCount))

	b.WriteString("## Streams\n\n")
	if streams.Size() == 0 {
		b.WriteString("_No streams created yet. Click **Create New Stream** above to lock your first GNOT vesting stream._\n")
		res.Write(b.String())
		return
	}

	b.WriteString("| ID | Label | Sender | Recipient | Total | Progress | Status |\n")
	b.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")

	streams.ReverseIterate("", "", func(_ string, value any) bool {
		s := value.(*Stream)
		_, _, _, bps := computeLiveMetrics(s, now)
		bar := streammath.ProgressBar(bps, 10)
		lbl := s.Label
		if lbl == "" {
			lbl = "—"
		}
		b.WriteString(ufmt.Sprintf(
			"| [#%d](%s:stream/%d) | %s | [%s](%s:addr/%s) | [%s](%s:addr/%s) | %s | `%s` | %s |\n",
			s.ID, realmURLPath, s.ID,
			escapeMarkdownCell(lbl),
			shortAddr(s.Sender), realmURLPath, s.Sender.String(),
			shortAddr(s.Recipient), realmURLPath, s.Recipient.String(),
			streammath.FormatUGNOT(s.TotalAmount),
			bar,
			statusBadge(s.Status),
		))
		return false
	})

	b.WriteString("\n---\n")
	b.WriteString("_Powered by pure 128-bit zero-dust math package `p/.../streammath`._\n")
	res.Write(b.String())
}

func renderStreamDetail(res *mux.ResponseWriter, req *mux.Request) {
	rawID := req.GetVar("id")
	id, err := strconv.ParseUint(rawID, 10, 64)
	if err != nil {
		res.Write(ufmt.Sprintf("# Invalid Stream ID\n\n`%s` is not a valid stream ID.\n\n[← Back to Dashboard](%s)\n", rawID, realmURLPath))
		return
	}

	s := getStream(id)
	if s == nil {
		res.Write(ufmt.Sprintf("# Stream #%d Not Found\n\n[← Back to Dashboard](%s)\n", id, realmURLPath))
		return
	}

	now := runtime.ChainHeight()
	vested, withdrawable, remaining, bps := computeLiveMetrics(s, now)
	bar := streammath.ProgressBar(bps, 20)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("[← Back to Dashboard](%s)\n\n", realmURLPath))
	title := ufmt.Sprintf("# Stream #%d", s.ID)
	if s.Label != "" {
		title += " — " + escapeMarkdownCell(s.Label)
	}
	b.WriteString(title + "\n\n")
	b.WriteString(ufmt.Sprintf("**Status:** %s · **Cancellable:** `%t` · **Live Height:** `#%d`\n\n", statusBadge(s.Status), s.Cancellable, now))
	b.WriteString(ufmt.Sprintf("`%s`\n\n", bar))

	b.WriteString("## Escrow & Schedule Details\n\n")
	b.WriteString("| Field | Value |\n")
	b.WriteString("| --- | --- |\n")
	b.WriteString(ufmt.Sprintf("| Sender | [%s](%s:addr/%s) |\n", s.Sender.String(), realmURLPath, s.Sender.String()))
	b.WriteString(ufmt.Sprintf("| Recipient | [%s](%s:addr/%s) |\n", s.Recipient.String(), realmURLPath, s.Recipient.String()))
	b.WriteString(ufmt.Sprintf("| Total Escrowed | **%s** (`%d ugnot`) |\n", streammath.FormatUGNOT(s.TotalAmount), s.TotalAmount))
	b.WriteString(ufmt.Sprintf("| Vested | %s (`%d ugnot`) |\n", streammath.FormatUGNOT(vested), vested))
	b.WriteString(ufmt.Sprintf("| Already Withdrawn | %s (`%d ugnot`) |\n", streammath.FormatUGNOT(s.Withdrawn), s.Withdrawn))
	b.WriteString(ufmt.Sprintf("| **Withdrawable Now** | **%s** (`%d ugnot`) |\n", streammath.FormatUGNOT(withdrawable), withdrawable))
	if s.Status == StatusCancelled {
		b.WriteString(ufmt.Sprintf("| Refunded to Sender | %s (`%d ugnot`) |\n", streammath.FormatUGNOT(s.Refunded), s.Refunded))
		b.WriteString(ufmt.Sprintf("| Cancelled At Height | `#%d` |\n", s.CancelledHeight))
	} else {
		b.WriteString(ufmt.Sprintf("| Remaining Unwithdrawn | %s (`%d ugnot`) |\n", streammath.FormatUGNOT(remaining), remaining))
	}
	b.WriteString(ufmt.Sprintf("| Schedule (Start / Cliff / End) | `#%d` / `#%d` / `#%d` |\n", s.StartHeight, s.CliffHeight, s.EndHeight))
	b.WriteString(ufmt.Sprintf("| Created At Height | `#%d` |\n\n", s.CreatedHeight))

	// Zero-dust conservation proof display
	accounted := s.Withdrawn + s.Refunded + remaining
	b.WriteString(ufmt.Sprintf("> **Zero-Dust Conservation Check:** `withdrawn (%d) + refunded (%d) + remaining (%d) == total (%d)`\n\n",
		s.Withdrawn, s.Refunded, remaining, accounted))

	if s.Status == StatusActive {
		idStr := strconv.FormatUint(s.ID, 10)
		withdrawURL := txlink.NewLink("Withdraw").AddArgs("streamID", idStr).URL()
		topUpURL := txlink.NewLink("TopUpStream").AddArgs("streamID", idStr).SetSend("1000000ugnot").URL()

		b.WriteString("## Actions\n\n")
		b.WriteString(ufmt.Sprintf("- [💸 Withdraw Vested GNOT](%s) _(recipient only)_\n", withdrawURL))
		if now < s.EndHeight {
			b.WriteString(ufmt.Sprintf("- [➕ Top Up Stream](%s) _(sender only, before `#%d`)_\n", topUpURL, s.EndHeight))
		}
		if s.Cancellable {
			cancelURL := txlink.NewLink("CancelStream").AddArgs("streamID", idStr).URL()
			b.WriteString(ufmt.Sprintf("- [🛑 Cancel Stream (Zero-Dust Split)](%s) _(sender only)_\n", cancelURL))
		}
		b.WriteString("\n### CLI Example\n\n")
		b.WriteString("```bash\n")
		b.WriteString(ufmt.Sprintf("gnokey maketx call -pkgpath %s -func Withdraw -args %d <your-key>\n", realmPkgPath, s.ID))
		b.WriteString("```\n")
	}

	res.Write(b.String())
}

func renderAddressPortfolio(res *mux.ResponseWriter, req *mux.Request) {
	rawAddr := req.GetVar("address")
	addr := address(rawAddr)
	now := runtime.ChainHeight()

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("[← Back to Dashboard](%s)\n\n", realmURLPath))
	b.WriteString(ufmt.Sprintf("# Portfolio: `%s`\n\n", rawAddr))
	b.WriteString(ufmt.Sprintf("Live Chain Height: **`#%d`**\n\n", now))

	incoming := collectStreamsByIndex(byRecipient, addr)
	outgoing := collectStreamsByIndex(bySender, addr)

	var totalIncoming, totalClaimable, totalOutgoing int64
	for _, s := range incoming {
		totalIncoming += s.TotalAmount
		_, w, _, _ := computeLiveMetrics(s, now)
		totalClaimable += w
	}
	for _, s := range outgoing {
		totalOutgoing += s.TotalAmount
	}

	b.WriteString("| Portfolio Summary | Amount |\n")
	b.WriteString("| --- | --- |\n")
	b.WriteString(ufmt.Sprintf("| Incoming Streams (%d) | %s |\n", len(incoming), streammath.FormatUGNOT(totalIncoming)))
	b.WriteString(ufmt.Sprintf("| **Claimable Now** | **%s** |\n", streammath.FormatUGNOT(totalClaimable)))
	b.WriteString(ufmt.Sprintf("| Outgoing Streams (%d) | %s |\n\n", len(outgoing), streammath.FormatUGNOT(totalOutgoing)))

	b.WriteString("## Incoming Streams (Recipient)\n\n")
	renderStreamList(&b, incoming, now, false)

	b.WriteString("\n## Outgoing Streams (Sender)\n\n")
	renderStreamList(&b, outgoing, now, true)

	res.Write(b.String())
}

func renderStreamList(b *strings.Builder, list []*Stream, now int64, isOutgoing bool) {
	if len(list) == 0 {
		b.WriteString("_None._\n")
		return
	}
	counterpartyCol := "Sender"
	if isOutgoing {
		counterpartyCol = "Recipient"
	}
	b.WriteString(ufmt.Sprintf("| ID | Label | %s | Total | Withdrawable | Progress | Status |\n", counterpartyCol))
	b.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")
	for _, s := range list {
		_, withdrawable, _, bps := computeLiveMetrics(s, now)
		cp := s.Sender
		if isOutgoing {
			cp = s.Recipient
		}
		lbl := s.Label
		if lbl == "" {
			lbl = "—"
		}
		b.WriteString(ufmt.Sprintf(
			"| [#%d](%s:stream/%d) | %s | [%s](%s:addr/%s) | %s | %s | `%s` | %s |\n",
			s.ID, realmURLPath, s.ID,
			escapeMarkdownCell(lbl),
			shortAddr(cp), realmURLPath, cp.String(),
			streammath.FormatUGNOT(s.TotalAmount),
			streammath.FormatUGNOT(withdrawable),
			streammath.ProgressBar(bps, 10),
			statusBadge(s.Status),
		))
	}
}

// --- Internal helpers ---

func requireUGNOTSent() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != DenomUGNOT || sent[0].Amount <= 0 {
		panic("StreamLedger: must send positive ugnot only")
	}
	return sent[0].Amount
}

func sanitizeLabel(label string) string {
	clean := strings.TrimSpace(label)
	if len(clean) > MaxLabelLength {
		panic("StreamLedger: label exceeds maximum length of 120 bytes")
	}
	return clean
}

func formatIDKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	if len(s) < 20 {
		return strings.Repeat("0", 20-len(s)) + s
	}
	return s
}

func indexKey(addr address, idKey string) string {
	return addr.String() + ":" + idKey
}

func getStream(id uint64) *Stream {
	if id == 0 {
		return nil
	}
	v := streams.Get(formatIDKey(id))
	if v == nil {
		return nil
	}
	return v.(*Stream)
}

func mustGetStream(id uint64) *Stream {
	s := getStream(id)
	if s == nil {
		panic("StreamLedger: stream not found")
	}
	return s
}

func collectStreamsByIndex(idx *avl.Tree, addr address) []*Stream {
	prefix := addr.String() + ":"
	end := addr.String() + ";"
	var result []*Stream
	idx.ReverseIterate(prefix, end, func(key string, value any) bool {
		if !strings.HasPrefix(key, prefix) {
			return false
		}
		if id, ok := value.(uint64); ok {
			if s := getStream(id); s != nil {
				result = append(result, s)
			}
		}
		return false
	})
	return result
}

func computeLiveMetrics(s *Stream, now int64) (vested, withdrawable, remaining, bps int64) {
	switch s.Status {
	case StatusCompleted:
		return s.TotalAmount, 0, 0, streammath.MaxBps
	case StatusCancelled:
		return s.Withdrawn, 0, 0, streammath.ProgressBps(s.StartHeight, s.EndHeight, s.CancelledHeight)
	default:
		vested = streammath.VestedAmount(s.TotalAmount, s.StartHeight, s.CliffHeight, s.EndHeight, now)
		withdrawable = streammath.WithdrawableAmount(s.TotalAmount, s.Withdrawn, s.StartHeight, s.CliffHeight, s.EndHeight, now)
		remaining = s.TotalAmount - s.Withdrawn
		bps = streammath.ProgressBps(s.StartHeight, s.EndHeight, now)
		return vested, withdrawable, remaining, bps
	}
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func statusBadge(status string) string {
	switch status {
	case StatusActive:
		return "🟢 ACTIVE"
	case StatusCompleted:
		return "✅ COMPLETED"
	case StatusCancelled:
		return "🛑 CANCELLED"
	default:
		return status
	}
}

func escapeMarkdownCell(s string) string {
	s = strings.ReplaceAll(s, "|", "\\|")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", "")
	return s
}

func escapeJSON(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	s = strings.ReplaceAll(s, "\n", `\n`)
	s = strings.ReplaceAll(s, "\r", `\r`)
	s = strings.ReplaceAll(s, "\t", `\t`)
	return s
}
