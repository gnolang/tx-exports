package lotto

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const AddNumberEvent = "AddNumber"

var holdings = bptree.NewBPTree32()

// AddNumber increments the holding once per successful call, including retries.
// Only the direct admin or operator caller may register a number. Individual
// ticket identities, issuance times and past round balances are not retained.
func AddNumber(cur realm, owner address, number uint64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertValidAddress(owner)
	key := strconv.FormatUint(number, 10) + ":" + owner.String()
	count := uint64(0)
	if current := holdings.Get(key); current != nil {
		count = current.(uint64)
	}
	if count == ^uint64(0) {
		panic("number count overflow")
	}
	count++
	holdings.Set(key, count)
	chain.Emit(
		AddNumberEvent,
		"owner", owner.String(),
		"number", strconv.FormatUint(number, 10),
		"count", strconv.FormatUint(count, 10),
	)
}

func DeleteAll(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	holdings = bptree.NewBPTree32()
}

// GetNumberCount returns zero when the valid owner has no holding for number.
func GetNumberCount(number uint64, owner address) uint64 {
	assertValidAddress(owner)
	current := holdings.Get(strconv.FormatUint(number, 10) + ":" + owner.String())
	if current == nil {
		return 0
	}
	return current.(uint64)
}

// ListOwnersByNumber returns fresh values in ascending address order. A cursor
// need not be stored. Each row carries the page cursor; an empty cursor or empty
// list ends pagination. Counts are decimal strings to preserve uint64 precision.
// Pages reflect current state, not a historical snapshot.
func ListOwnersByNumber(number uint64, afterOwner string, limit int) []map[string]string {
	if afterOwner != "" {
		assertValidAddress(address(afterOwner))
	}
	assertListLimit(limit)
	numberStr := strconv.FormatUint(number, 10)
	prefix := numberStr + ":"
	start := prefix
	if afterOwner != "" {
		// Valid address strings cannot contain NUL, so this excludes the cursor
		// without visiting it or scanning preceding owners.
		start += afterOwner + "\x00"
	}
	result := make([]map[string]string, 0, limit)
	nextOwner := ""
	holdings.Iterate(start, numberStr+";", func(key string, count any) bool {
		if len(result) == limit {
			nextOwner = result[len(result)-1]["owner"]
			return true
		}
		result = append(result, map[string]string{
			"owner":     key[len(prefix):],
			"count":     strconv.FormatUint(count.(uint64), 10),
			"nextOwner": "",
		})
		return false
	})
	for _, item := range result {
		item["nextOwner"] = nextOwner
	}
	return result
}
