package definition

import (
	"chain/runtime/unsafe"
	"net/url"
	"sort"
	"strings"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

type Field struct {
	Key   string
	Value string
}

var definitions *bptree.BPTree

func init() {
	definitions = bptree.NewBPTree32()
}

// DeleteAll removes all definitions so an administrator can reload the catalog.
func DeleteAll(cur realm) {
	assertCanWrite(0, cur)
	definitions = bptree.NewBPTree32()
}

// SetDefinitions accepts URL-escaped keys and query-encoded field objects as paired
// comma-separated strings, so MsgCall can pass a batch without realm DTOs.
func SetDefinitions(cur realm, keys, values string) {
	assertCanWrite(0, cur)
	if len(keys)+len(values) > 131071 {
		panic("call bytes exceeds 131071")
	}
	if keys == "" && values == "" {
		assertBatchCount(0)
	}
	if keys == "" || values == "" {
		panic("keys and values count mismatch")
	}
	type entry struct {
		Key    string
		Fields []Field
	}
	entries := []entry{}
	keyStart, keyEnd := 0, 0
	valueStart, valueEnd := 0, 0
	for {
		assertBatchCount(len(entries) + 1)
		for keyEnd < len(keys) && keys[keyEnd] != ',' {
			keyEnd++
		}
		for valueEnd < len(values) && values[valueEnd] != ',' {
			valueEnd++
		}
		if keyStart == keyEnd || valueStart == valueEnd {
			panic("empty entry token")
		}
		key, err := url.QueryUnescape(keys[keyStart:keyEnd])
		if err != nil {
			panic("invalid encoded key")
		}
		attributes, err := url.ParseQuery(values[valueStart:valueEnd])
		if err != nil {
			panic("invalid encoded fields")
		}
		if len(attributes) < 1 || len(attributes) > 32 {
			panic("field count must be between 1 and 32")
		}
		fields := make([]Field, 0, len(attributes))
		for name, fieldValues := range attributes {
			if len(fieldValues) != 1 {
				panic("duplicate field key")
			}
			fields = append(fields, Field{name, fieldValues[0]})
		}
		entries = append(entries, entry{key, fields})
		keyDone := keyEnd >= len(keys)
		valueDone := valueEnd >= len(values)
		if keyDone != valueDone {
			panic("keys and values count mismatch")
		}
		if keyDone {
			break
		}
		keyEnd++
		valueEnd++
		keyStart, valueStart = keyEnd, valueEnd
	}
	// Prepare every final record before writing any state.
	prepared := make([][]Field, len(entries))
	batchBytes := 0
	for i, entry := range entries {
		assertIdentifier(entry.Key, "key", 128)
		batchBytes += len(entry.Key) + assertFields(entry.Fields)
		if batchBytes > 65536 {
			panic("batch bytes exceeds 65536")
		}
		for j := 0; j < i; j++ {
			if entries[j].Key == entry.Key {
				panic("duplicate entry")
			}
		}
		fields, _ := getFields(entry.Key)
		for _, update := range entry.Fields {
			found := false
			for j := range fields {
				if fields[j].Key == update.Key {
					fields[j].Value = update.Value
					found = true
					break
				}
			}
			if !found {
				fields = append(fields, update)
			}
		}
		assertFields(fields)
		// At most 32 fields; insertion sort avoids another persistent index.
		for j := 1; j < len(fields); j++ {
			for k := j; k > 0 && fields[k].Key < fields[k-1].Key; k-- {
				fields[k], fields[k-1] = fields[k-1], fields[k]
			}
		}
		prepared[i] = fields
	}
	for i, entry := range entries {
		definitions.Set(entry.Key, prepared[i])
	}
}

// Get returns ordered field records. An empty list means the key is absent;
// stored definitions always contain at least one field.
func Get(key string) []map[string]string {
	fields, _ := getFields(key)
	result := make([]map[string]string, 0, len(fields))
	for _, field := range fields {
		result = append(result, map[string]string{"key": field.Key, "value": field.Value})
	}
	return result
}

func getFields(key string) (fields []Field, found bool) {
	if !definitions.Has(key) {
		return nil, false
	}
	stored := definitions.Get(key).([]Field)
	fields = make([]Field, len(stored))
	copy(fields, stored)
	return fields, true
}

// GetField includes "value" even when it is empty. An empty map means absent.
func GetField(key, fieldKey string) map[string]string {
	fields, _ := getFields(key)
	for _, field := range fields {
		if field.Key == fieldKey {
			return map[string]string{"value": field.Value}
		}
	}
	return map[string]string{}
}

func GetKeyCount() int { return definitions.Size() }

func ListKeys(page, count int) []string {
	assertPage(page, count)
	result := []string{}
	// Compare before multiplication so an extreme page cannot overflow.
	if definitions.Size() == 0 || page-1 > (definitions.Size()-1)/count {
		return result
	}
	// Sort a query-local view so existing records keep their original storage keys.
	ordered := make([]string, 0, definitions.Size())
	definitions.Iterate("", "", func(key string, _ any) bool {
		numeric := true
		for _, r := range key {
			if r < '0' || r > '9' {
				numeric = false
				break
			}
		}
		if numeric {
			// Keys are at most 128 bytes. Padding avoids integer overflow; the
			// original key breaks ties such as "01" and "1" without merging them.
			ordered = append(ordered, "0"+strings.Repeat("0", 128-len(key))+key+":"+key)
		} else {
			ordered = append(ordered, "1:"+key)
		}
		return false
	})
	sort.Strings(ordered)
	start := (page - 1) * count
	end := start + count
	if end > len(ordered) {
		end = len(ordered)
	}
	for _, key := range ordered[start:end] {
		result = append(result, key[strings.IndexByte(key, ':')+1:])
	}
	return result
}

func assertCanWrite(_ int, rlm realm) {
	accesscontrol.AssertIsAdmin(0, rlm, admin.IsAdmin)
	// MsgRun has the signer address but an ephemeral /e/<address>/run path.
	if !rlm.Previous().IsUser() {
		panic("direct user call or run required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
	}
}
