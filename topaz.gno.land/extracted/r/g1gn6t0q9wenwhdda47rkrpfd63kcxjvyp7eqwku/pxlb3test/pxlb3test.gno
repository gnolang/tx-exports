package pxlb3test

import (
	"strconv"
	"strings"

	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
)

var placementCounts avl.Tree

type placerCount struct {
	addr  string
	count int64
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func Bump(cur realm) {
	k := callerAddress().String()
	count, _ := placementCounts.Get(k).(int64)
	placementCounts.Set(k, count+1)
}

func TopPlacers(n int64) string {
	var entries []placerCount
	placementCounts.Iterate("", "", func(k string, v any) bool {
		entries = append(entries, placerCount{k, v.(int64)})
		return false
	})
	for i := 1; i < len(entries); i++ {
		cur := entries[i]
		j := i - 1
		for j >= 0 && entries[j].count < cur.count {
			entries[j+1] = entries[j]
			j--
		}
		entries[j+1] = cur
	}
	if n >= 0 && int64(len(entries)) > n {
		entries = entries[:n]
	}
	var b strings.Builder
	for i, e := range entries {
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(e.addr + "," + strconv.FormatInt(e.count, 10))
	}
	return b.String()
}
