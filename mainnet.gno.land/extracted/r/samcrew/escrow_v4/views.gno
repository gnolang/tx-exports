package escrow_v4

// Read-only views: NF-2 solvency getters, counters, governance reads, JSON
// views for frontends and Render. Nothing here changes state. (All of this
// sits in one file, like the state-changing code in escrow.gno, because every
// extra file costs AddPackage storage.)

import (
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
	cfg "gno.land/r/samcrew/memba_market_config"
)

// ── NF-2 solvency getters (MAINNET_READINESS.md §3) ─────────────────────────
//
// Invariant the solvency monitor reconciles: realm balance >=
// TotalLiabilities(). totalLiable rises by the milestone amount in
// FundMilestone and falls by it at every point funds leave the realm.

// TotalLiabilities returns the ugnot the realm owes across funded, completed
// and disputed milestones.
func TotalLiabilities() int64 { return totalLiable }

// RealmAddress is the NF-2 canonical name for the realm's own address.
func RealmAddress() string { return realmAddress().String() }

// ── Slot and archive counters ─────────────────────────────────────────────

// GetActiveCount returns the number of open contracts (not completed or
// cancelled).
func GetActiveCount() int { return activeCount }

// GetClientActiveCount returns the open contracts created by client, bounded
// by MaxActivePerClient.
func GetClientActiveCount(client address) int { return clientActive(client) }

// GetLiveCount returns the contracts still stored: open ones plus settled ones
// their client has not archived.
func GetLiveCount() int { return contracts.Size() }

// GetArchivedCount returns the contracts deleted by ArchiveContract.
func GetArchivedCount() int { return archivedCount }

// GetCreatedCount returns every contract ever created; ids run from 0 to
// GetCreatedCount()-1 and are never reused.
func GetCreatedCount() int { return nextID }

// Value-only reads for the memba_dao escrow adapter, unchanged from escrow_v3:
// no Contract pointer or persistent milestone slice escapes. An archived
// contract reads as absent (Exists false).

type GovernanceMilestone struct {
	ID                                int
	Amount                            int64
	Status                            string
	FundedAt, CompletedAt, DisputedAt int64
	PreDisputeStatus                  string
}

type GovernanceContract struct {
	Exists                  bool
	ID, ContentHash, Status string
	Client, Freelancer      address
	Count                   int
	Milestones              [20]GovernanceMilestone
}

func GetGovernanceContract(id string) GovernanceContract {
	v, ok := contracts.Get(id)
	if !ok {
		return GovernanceContract{}
	}
	c := v.(*Contract)
	if len(c.Milestones) > MaxMilestones {
		panic("invalid escrow milestone count")
	}
	s := GovernanceContract{Exists: true, ID: c.ID, Status: string(c.Status), Client: c.Client, Freelancer: c.Freelancer, Count: len(c.Milestones), ContentHash: contentHash(c)}
	for i, m := range c.Milestones {
		s.Milestones[i] = GovernanceMilestone{ID: m.ID, Amount: m.Amount, Status: string(m.Status), FundedAt: m.FundedAt, CompletedAt: m.CompletedAt, DisputedAt: m.DisputedAt, PreDisputeStatus: string(m.PreDisputeStatus)}
	}
	return s
}

// contentHash digests the immutable metadata of a contract (parties, texts,
// creation height, milestone titles and amounts), not its state.
func contentHash(c *Contract) string {
	metadata := "escrow-metadata/v1" + escrowMetadataField(c.ID) + escrowMetadataField(string(c.Client)) + escrowMetadataField(string(c.Freelancer)) + escrowMetadataField(c.Title) + escrowMetadataField(c.Description) + escrowMetadataField(strconv.FormatInt(c.CreatedAt, 10)) + escrowMetadataField(strconv.Itoa(len(c.Milestones)))
	for _, m := range c.Milestones {
		metadata += escrowMetadataField(strconv.Itoa(m.ID)) + escrowMetadataField(m.Title) + escrowMetadataField(strconv.FormatInt(m.Amount, 10))
	}
	digest := sha256.Sum256([]byte(metadata))
	return hex.EncodeToString(digest[:])
}

type GovernanceFeeTerms struct {
	RawBPS, EffectiveBPS                             int64
	RawTreasury, FallbackTreasury, EffectiveTreasury address
}

func GetGovernanceFeeTerms() GovernanceFeeTerms {
	bps, treasury := resolveFee()
	return GovernanceFeeTerms{RawBPS: int64(cfg.GetFeeBPS(laneService)), EffectiveBPS: bps, RawTreasury: cfg.GetTreasury(), FallbackTreasury: feeRecipient, EffectiveTreasury: treasury}
}

func escrowMetadataField(value string) string { return strconv.Itoa(len(value)) + ":" + value }

// Structured read-only views for frontends (additive to the frozen API; they
// change no state and no existing behaviour). Every integer is a decimal
// string, absent values are null, and an unknown or archived id reads as
// {"exists":false,...}. Heights such as refundAt are pause-adjusted deadlines,
// assuming no further pause. Contract listings walk at most limit+1 entries
// of a per-party index, newest first.

const maxPageSize = 50

// indexPrefix keys the client index inside clientSlots (the per-client slot
// counters are keyed by the bare address, which never starts with "c/"): one
// tree instead of two keeps the package smaller.
const indexPrefix = "c/"

// GetContractJSON returns one contract as JSON.
func GetContractJSON(id string) string {
	v, ok := contracts.Get(id)
	if !ok {
		return `{"exists":false,"id":` + jstr(id) + `}`
	}
	c := v.(*Contract)
	var total, escrowed, released, refunded, fundedAt, refundAt, resolveAt int64
	pending := true
	var ms strings.Builder
	for i, m := range c.Milestones {
		total += m.Amount
		mRefund, mResolve := int64(0), int64(0)
		switch m.Status {
		case MsFunded:
			mRefund = deadline(m.FundedAt, m.fundedPauseMark, AutoRefundBlks)
			refundAt = minHeight(refundAt, mRefund)
			escrowed += m.Amount
		case MsDisputed:
			mResolve = deadline(m.DisputedAt, m.disputedPauseMark, AutoResolveBlks)
			resolveAt = minHeight(resolveAt, mResolve)
			escrowed += m.Amount
		case MsCompleted:
			escrowed += m.Amount
		case MsReleased:
			released += m.Amount
		case MsRefunded:
			refunded += m.Amount
		}
		if m.Status != MsPending {
			pending = false
		}
		fundedAt = minHeight(fundedAt, m.FundedAt)
		if i > 0 {
			ms.WriteString(",")
		}
		ms.WriteString(`{"index":` + jint(int64(i)) + `,"title":` + jstr(m.Title) +
			`,"amountUgnot":` + jint(m.Amount) + `,"status":` + jstr(string(m.Status)) +
			`,"fundedAtHeight":` + jheight(m.FundedAt) + `,"completedAtHeight":` + jheight(m.CompletedAt) +
			`,"disputedAtHeight":` + jheight(m.DisputedAt) + `,"refundAt":` + jheight(mRefund) +
			`,"resolveAt":` + jheight(mResolve) + `}`)
	}
	expireAt := int64(0)
	if pending && c.Status == StatusActive {
		expireAt = deadline(c.CreatedAt, c.createdPauseMark, UnfundedExpiryBlks)
	}
	return `{"exists":true,"id":` + jstr(c.ID) + `,"client":` + jstr(c.Client.String()) +
		`,"freelancer":` + jstr(c.Freelancer.String()) + `,"title":` + jstr(c.Title) +
		`,"description":` + jstr(c.Description) + `,"status":` + jstr(string(c.Status)) +
		`,"createdAtHeight":` + jint(c.CreatedAt) + `,"fundedAtHeight":` + jheight(fundedAt) +
		`,"refundAt":` + jheight(refundAt) + `,"expireAt":` + jheight(expireAt) + `,"resolveAt":` + jheight(resolveAt) +
		`,"milestones":[` + ms.String() + `],"totals":{"amountUgnot":` + jint(total) +
		`,"escrowedUgnot":` + jint(escrowed) + `,"releasedUgnot":` + jint(released) +
		`,"refundedUgnot":` + jint(refunded) + `}}`
}

// GetClientContractsJSON pages the live contracts a client created, newest
// first: {"items":[{"id","status","createdAtHeight"}...],"next":cursor|null}.
// before is "" for the first page or the previous page's next cursor; limit
// is clamped to 1..50.
func GetClientContractsJSON(client address, before string, limit int) string {
	return contractsPage(client, before, limit)
}

// GetPauseStateJSON returns PauseState() as JSON.
func GetPauseStateJSON() string {
	p := PauseState()
	return `{"paused":` + strconv.FormatBool(p.Paused) + `,"pausedAt":` + jheight(p.PausedAt) +
		`,"exitsReopenAt":` + jheight(p.ExitsReopenAt) + `,"exitsOpen":` + strconv.FormatBool(p.ExitsOpen) +
		`,"cooldownUntil":` + jint(p.CooldownUntil) + `,"pausedBlocks":` + jint(p.PausedBlocks) + `}`
}

func contractsPage(who address, before string, limit int) string {
	if limit < 1 {
		limit = 1
	} else if limit > maxPageSize {
		limit = maxPageSize
	}
	prefix := indexPrefix + who.String() + "/"
	end := prefix + "~" // after every digit
	if before != "" {
		n, err := strconv.Atoi(before)
		if err != nil || n < 0 || strconv.Itoa(n) != before {
			panic("invalid cursor: " + before)
		}
		end = indexKey(who, n)
	}
	var sb strings.Builder
	count, next, last := 0, "null", ""
	clientSlots.ReverseIterate(prefix, end, func(key string, _ any) bool {
		n, _ := strconv.Atoi(key[len(prefix):])
		id := strconv.Itoa(n)
		if id == before {
			return false // end is inclusive; the cursor itself was on the previous page
		}
		if count == limit {
			next = jstr(last)
			return true
		}
		c := getContract(id)
		if count > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"id":` + jstr(id) + `,"status":` + jstr(string(c.Status)) +
			`,"createdAtHeight":` + jint(c.CreatedAt) + `}`)
		count++
		last = id
		return false
	})
	return `{"items":[` + sb.String() + `],"next":` + next + `}`
}

// indexKey orders a party's contracts by id: 10-digit zero padding.
func indexKey(who address, id int) string {
	s := strconv.Itoa(id)
	return indexPrefix + who.String() + "/" + strings.Repeat("0", 10-len(s)) + s
}

// deadline is the height at which a clock started at since (pause mark taken
// then) reaches span unpaused blocks, assuming no pause after the current one.
func deadline(since, mark, span int64) int64 {
	now := runtime.ChainHeight()
	if inBlockingWindow(now) {
		now = pausedAt + MaxPauseBlks
	}
	return since + span + pausedBlocksAt(now) - mark
}

func minHeight(a, b int64) int64 {
	if a == 0 || (b != 0 && b < a) {
		return b
	}
	return a
}

func jint(n int64) string { return `"` + strconv.FormatInt(n, 10) + `"` }

// jheight encodes 0 (not set) as null.
func jheight(n int64) string {
	if n == 0 {
		return "null"
	}
	return jint(n)
}

// jstr quotes s as a JSON string. Stored text is valid UTF-8 without control
// characters; ids passed by callers are escaped the same way.
func jstr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte("0123456789abcdef"[r>>4])
			b.WriteByte("0123456789abcdef"[r&15])
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// Render() contract:
//   Home — Render("") or Render("page/N"):
//     # Escrow Contracts
//     | ID | Title | Client | Freelancer | Status | Total |
//     (RenderPageSize live contracts per page, in tree order)
//   Detail — Render("contract/ID"):
//     # Title
//     **Client:** g1...
//     **Freelancer:** g1...
//     **Status:** active
//     ## Milestones
//     - **Milestone Title** — 1000000 ugnot [funded]
//   Stats — Render("stats"): counters only, no iteration.
// Archived contracts are gone from every view.

// RenderPageSize is the number of contracts listed per home page.
const RenderPageSize = 20

func Render(path string) string {
	switch {
	case path == "":
		return renderHome(1)
	case strings.HasPrefix(path, "page/"):
		page, err := strconv.Atoi(strings.TrimPrefix(path, "page/"))
		if err != nil || page < 1 {
			return "# 404\nNot found: " + path
		}
		return renderHome(page)
	case strings.HasPrefix(path, "contract/"):
		return renderContract(strings.TrimPrefix(path, "contract/"))
	case path == "stats":
		return renderStats()
	}
	return "# 404\nNot found: " + path
}

func renderHome(page int) string {
	var sb strings.Builder
	sb.WriteString("# Escrow Contracts\n\n")
	sb.WriteString("Milestone-based escrow for freelance services on Gno.\n\n")

	live := contracts.Size()
	if live == 0 {
		sb.WriteString("*No contracts yet.*\n")
		return sb.String()
	}
	offset := (page - 1) * RenderPageSize
	if offset >= live {
		return "# 404\nNo page " + strconv.Itoa(page)
	}

	sb.WriteString("| ID | Title | Client | Freelancer | Status | Total |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	contracts.IterateByOffset(offset, RenderPageSize, func(_ string, value any) bool {
		c := value.(*Contract)
		sb.WriteString(ufmt.Sprintf("| %s | [%s](:contract/%s) | %s | %s | %s | %d ugnot |\n",
			c.ID, c.Title, c.ID, truncAddr(c.Client), truncAddr(c.Freelancer),
			string(c.Status), contractTotal(c)))
		return false
	})
	if offset+RenderPageSize < live {
		sb.WriteString(ufmt.Sprintf("\n[Next page](:page/%d)\n", page+1))
	}
	return sb.String()
}

func renderContract(id string) string {
	val, exists := contracts.Get(id)
	if !exists {
		return "# 404\nContract not found: " + id
	}
	c := val.(*Contract)

	var sb strings.Builder
	sb.WriteString("# " + c.Title + "\n\n")
	if len(c.Description) > 0 {
		sb.WriteString(c.Description + "\n\n")
	}
	sb.WriteString("**ID:** " + c.ID + "\n")
	sb.WriteString("**Client:** " + c.Client.String() + "\n")
	sb.WriteString("**Freelancer:** " + c.Freelancer.String() + "\n")
	sb.WriteString("**Status:** " + string(c.Status) + "\n")
	sb.WriteString("**Created:** block " + strconv.FormatInt(c.CreatedAt, 10) + "\n\n")
	sb.WriteString("**Total Value:** " + strconv.FormatInt(contractTotal(c), 10) + " ugnot\n\n")

	sb.WriteString("## Milestones\n\n")
	for _, ms := range c.Milestones {
		sb.WriteString(ufmt.Sprintf("- **%s** — %d ugnot [%s]", ms.Title, ms.Amount, string(ms.Status)))
		if ms.FundedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (funded block %d)", ms.FundedAt))
		}
		if ms.CompletedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (completed block %d)", ms.CompletedAt))
		}
		if ms.DisputedAt > 0 {
			sb.WriteString(ufmt.Sprintf(" (disputed block %d)", ms.DisputedAt))
		}
		sb.WriteString("\n")
	}
	return sb.String()
}

func renderStats() string {
	var sb strings.Builder
	sb.WriteString("# Escrow Stats\n\n")
	sb.WriteString(ufmt.Sprintf("**Created:** %d\n", nextID))
	sb.WriteString(ufmt.Sprintf("**Open:** %d (at most %d per client)\n", activeCount, MaxActivePerClient))
	sb.WriteString(ufmt.Sprintf("**Settled, not archived:** %d\n", contracts.Size()-activeCount))
	sb.WriteString(ufmt.Sprintf("**Archived:** %d\n", archivedCount))
	sb.WriteString(ufmt.Sprintf("**Liabilities:** %d ugnot\n", totalLiable))
	p := PauseState()
	switch {
	case !p.Paused:
		sb.WriteString("**Paused:** no\n")
	case !p.ExitsOpen:
		sb.WriteString(ufmt.Sprintf("**Paused:** yes, since block %d; exits reopen at block %d\n", p.PausedAt, p.ExitsReopenAt))
	default:
		sb.WriteString(ufmt.Sprintf("**Paused:** new contracts and funding only, since block %d\n", p.PausedAt))
	}
	return sb.String()
}

// contractTotal cannot overflow: CreateContract refuses totals above int64.
func contractTotal(c *Contract) int64 {
	total := int64(0)
	for _, ms := range c.Milestones {
		total += ms.Amount
	}
	return total
}

func truncAddr(addr address) string {
	s := addr.String()
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}
