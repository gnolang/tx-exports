package trickle

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const maxPageSize = 50

// Count returns the number of streams ever created.
func Count() int { return streams.Size() }

// Withdrawable returns the ugnot the recipient of stream id can claim now.
func Withdrawable(id uint64) int64 {
	return mustGet(id).Withdrawable(time.Now().Unix())
}

// StreamJSON returns stream id as a JSON object.
func StreamJSON(id uint64) string {
	return mustGet(id).json(time.Now().Unix())
}

// StatsJSON returns realm-wide totals as a JSON object.
func StatsJSON() string {
	return `{"streams":` + strconv.Itoa(streams.Size()) +
		`,"deposited":` + strconv.FormatInt(totalDeposited, 10) +
		`,"paid":` + strconv.FormatInt(totalPaid, 10) +
		`,"refunded":` + strconv.FormatInt(totalRefunded, 10) +
		`,"locked":` + strconv.FormatInt(totalDeposited-totalPaid-totalRefunded, 10) +
		`,"now":` + strconv.FormatInt(time.Now().Unix(), 10) + `}`
}

// LatestJSON returns up to limit streams, newest first, skipping offset,
// as a JSON array.
func LatestJSON(offset, limit int) string {
	now := time.Now().Unix()
	var out []string
	streams.ReverseIterateByOffset(clampOffset(offset), clampLimit(limit), func(_ string, v any) bool {
		out = append(out, v.(*Record).json(now))
		return false
	})
	return "[" + strings.Join(out, ",") + "]"
}

// IncomingJSON returns streams whose recipient is addr, newest first.
func IncomingJSON(addr address, offset, limit int) string {
	return indexJSON(byRecipient, addr, offset, limit)
}

// OutgoingJSON returns streams whose sender is addr, newest first.
func OutgoingJSON(addr address, offset, limit int) string {
	return indexJSON(bySender, addr, offset, limit)
}

func indexJSON(index *avl.Tree, addr address, offset, limit int) string {
	now := time.Now().Unix()
	var out []string
	eachOf(index, addr, clampOffset(offset), clampLimit(limit), func(r *Record) {
		out = append(out, r.json(now))
	})
	return "[" + strings.Join(out, ",") + "]"
}

// eachOf walks the streams indexed under addr, newest first.
func eachOf(index *avl.Tree, addr address, offset, limit int, fn func(*Record)) {
	if !addr.IsValid() {
		return
	}
	prefix := addr.String() + ":"
	i := 0
	// ';' is the byte after ':', so [prefix, addr+";") spans exactly addr's keys.
	index.ReverseIterate(prefix, addr.String()+";", func(key string, _ any) bool {
		if i >= offset+limit {
			return true
		}
		if i >= offset {
			if id, err := seqid.FromString(strings.TrimPrefix(key, prefix)); err == nil {
				if r := get(uint64(id)); r != nil {
					fn(r)
				}
			}
		}
		i++
		return false
	})
}

func clampOffset(offset int) int {
	if offset < 0 {
		return 0
	}
	return offset
}

func clampLimit(limit int) int {
	if limit <= 0 || limit > maxPageSize {
		return maxPageSize
	}
	return limit
}

func (r *Record) json(now int64) string {
	i := func(v int64) string { return strconv.FormatInt(v, 10) }
	return `{"id":` + strconv.FormatUint(r.ID, 10) +
		`,"sender":"` + r.Sender.String() +
		`","recipient":"` + r.Recipient.String() +
		`","deposit":` + i(r.Deposit) +
		`,"start":` + i(r.Start) +
		`,"cliff":` + i(r.Cliff) +
		`,"end":` + i(r.End) +
		`,"withdrawn":` + i(r.Withdrawn) +
		`,"withdrawable":` + i(r.Withdrawable(now)) +
		`,"refunded":` + i(r.Refunded) +
		`,"canceledAt":` + i(r.CanceledAt) +
		`,"cancelable":` + strconv.FormatBool(r.Cancelable) +
		`,"status":"` + r.Status(now).String() +
		`","createdAt":` + i(r.CreatedAt) +
		`,"memo":` + jsonString(r.Memo) + `}`
}

// jsonString quotes s as a JSON string. Memos are validated on entry to be
// UTF-8 without control characters, so only quotes and backslashes need
// escaping.
func jsonString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}
