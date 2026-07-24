package memba_arcade_leaderboard_v1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// ── Read getters (pure, non-failing; served via vm/qeval or Render) ─────────────

// GetOwner returns the current owner.
func GetOwner() address { return owner }

// IsPaused reports whether attestation is frozen.
func IsPaused() bool { return paused }

// IsAttester reports whether an address is on the attester allowlist.
func IsAttester(addr string) bool { return isAttester(addr) }

// BoardCount returns how many addresses hold an entry on a day's board (O(1)).
func BoardCount(day string) int {
	if v, ok := boardCount.Get(day); ok {
		return v.(int)
	}
	return 0
}

func entryJSON(e *Entry) string {
	return ufmt.Sprintf(
		`{"addr":"%s","day":"%s","mode":"%s","score":%d,"waves":%d,"won":%s,"overtimeRound":%d,"simVersion":%d,"stateHash":"%s","inputLogSha256":"%s","attestedAt":%d}`,
		jsonEscape(e.Addr.String()), jsonEscape(e.Day), jsonEscape(e.Mode), e.Score, e.Waves,
		boolStr(e.Won), e.OvertimeRound, e.SimVersion, jsonEscape(e.StateHash),
		jsonEscape(e.InputLogSha256), e.AttestedAt)
}

// GetEntryJSON returns one address's board entry for a day, or "null".
func GetEntryJSON(day, addr string) string {
	if v, ok := boards.Get(day + "|" + addr); ok {
		return entryJSON(v.(*Entry))
	}
	return "null"
}

// dayEntries collects a day's board entries in canonical rank order: score desc,
// then earlier attestation, then address — a total order, so pagination is stable.
func dayEntries(day string) []*Entry {
	var out []*Entry
	boards.Iterate(day+"|", day+"|~", func(_ string, v any) bool {
		out = append(out, v.(*Entry))
		return false
	})
	// Insertion sort (gno stdlib has no sort.Slice): a day's board is bounded
	// and reads are qeval-side — O(n²) on a few hundred entries is fine.
	for i := 1; i < len(out); i++ {
		e := out[i]
		j := i - 1
		for j >= 0 && ranksAfter(out[j], e) {
			out[j+1] = out[j]
			j--
		}
		out[j+1] = e
	}
	return out
}

// ranksAfter reports whether a should sit AFTER b in rank order — a total
// order (score desc, then earlier attestation, then address) so pagination
// is stable and identical everywhere.
func ranksAfter(a, b *Entry) bool {
	if a.Score != b.Score {
		return a.Score < b.Score
	}
	if a.AttestedAt != b.AttestedAt {
		return a.AttestedAt > b.AttestedAt
	}
	return a.Addr.String() > b.Addr.String()
}

// GetBoardJSON returns a page of a day's board, rank-ordered, as
// {"day":…,"total":N,"entries":[…]}. Reads sort the day's entries on demand —
// fine for a testnet-scale board; a rank index (points_v1-style) is the v2
// upgrade if daily boards grow past a few thousand entries.
func GetBoardJSON(day string, offset, limit int) string {
	all := dayEntries(day)
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf(`{"day":"%s","total":%d,"entries":[`, jsonEscape(day), len(all)))
	for i := offset; i < len(all) && i < offset+limit; i++ {
		if i > offset {
			sb.WriteString(",")
		}
		sb.WriteString(entryJSON(all[i]))
	}
	sb.WriteString("]}")
	return sb.String()
}

// GetReceiptsJSON returns a page of one address's training receipts, newest first, as
// {"addr":…,"total":N,"entries":[…]}.
func GetReceiptsJSON(addr string, offset, limit int) string {
	var ring []*Entry
	if v, ok := receipts.Get(addr); ok {
		ring = v.([]*Entry)
	}
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf(`{"addr":"%s","total":%d,"entries":[`, jsonEscape(addr), len(ring)))
	n := 0
	for i := len(ring) - 1 - offset; i >= 0 && n < limit; i-- {
		if n > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(entryJSON(ring[i]))
		n++
	}
	sb.WriteString("]}")
	return sb.String()
}

// Render serves a human-readable snapshot: `:board/YYYY-MM-DD` for a day's top
// entries, `:receipts/<addr>` for an address's latest receipts.
func Render(path string) string {
	if strings.HasPrefix(path, "board/") {
		day := path[len("board/"):]
		all := dayEntries(day)
		var sb strings.Builder
		sb.WriteString("# BARRICADE daily board — " + day + "\n\n")
		if len(all) == 0 {
			sb.WriteString("No attested runs yet.\n")
			return sb.String()
		}
		for i, e := range all {
			if i >= 50 {
				sb.WriteString(ufmt.Sprintf("\n…and %d more.\n", len(all)-50))
				break
			}
			verdict := "fell"
			if e.Won {
				verdict = "HELD"
			}
			sb.WriteString(ufmt.Sprintf("%d. `%s` — **%d** · wave %d · the line %s · siege r%d\n",
				i+1, e.Addr.String(), e.Score, e.Waves, verdict, e.OvertimeRound))
		}
		return sb.String()
	}
	if strings.HasPrefix(path, "receipts/") {
		addr := path[len("receipts/"):]
		return "# Training receipts — " + addr + "\n\n```json\n" + GetReceiptsJSON(addr, 0, 20) + "\n```\n"
	}
	return "# memba_arcade_leaderboard_v1\n\nVerified BARRICADE results — never a client-claimed number.\n\n" +
		"- `:board/YYYY-MM-DD` — a day's competitive board\n" +
		"- `:receipts/<addr>` — an address's training receipts\n"
}

// jsonEscape escapes a string for embedding in a JSON string literal (defensive — addresses are
// bech32 and hashes are hex, but the read path escapes regardless).
func jsonEscape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if r < 0x20 {
				sb.WriteString(ufmt.Sprintf("\\u%04x", r))
			} else {
				sb.WriteString(string(r))
			}
		}
	}
	return sb.String()
}
