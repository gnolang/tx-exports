package definition

import (
	"chain"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

var definitionAdmin = testutils.TestAddress("definitionAdmin")

// Call with cross(cur); each test gets fresh state and a direct admin caller.
func setupDefinition(cur realm, t *testing.T) {
	t.Helper()
	definitions = bptree.NewBPTree32()
	testing.SetOriginSend(chain.Coins{})
	if admin.GetAdmin() != definitionAdmin {
		testing.SetOriginCaller(admin.GetAdmin())
		testing.SetRealm(testing.NewUserRealm(admin.GetAdmin()))
		admin.TransferAdmin(cross(cur), definitionAdmin)
		testing.SetOriginCaller(definitionAdmin)
		testing.SetRealm(testing.NewUserRealm(definitionAdmin))
		admin.AcceptAdmin(cross(cur))
	}
	testing.SetOriginCaller(definitionAdmin)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
}

func TestStorageMergeAndCopies(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	uassert.Equal(t, 0, GetKeyCount())
	fields := []Field{{"z", ""}, {"name", "돌"}, {"description", " 줄\n바꿈 ` <tag> "}}
	setTestDefinition(cross(cur), "1101000", fields)
	fields[1].Value = "changed"
	setTestDefinition(cross(cur), "1101000", []Field{{"name", "Stone"}, {"a", "added"}})
	got := Get("1101000")
	assertFieldList(t, []Field{{"a", "added"}, {"description", " 줄\n바꿈 ` <tag> "}, {"name", "Stone"}, {"z", ""}}, got)
	got[0]["value"] = "mutated return"
	field := GetField("1101000", "a")
	field["value"] = "mutated field return"
	value, found := GetField("1101000", "a")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "added", value)
	value, found = GetField("1101000", "z")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "", value)
	_, found = GetField("1101000", "missing")["value"]
	uassert.False(t, found)
	uassert.Equal(t, len(Get("missing")), 0)
	uassert.Equal(t, 1, GetKeyCount())
	setTestDefinition(cross(cur), " A : 한글 ", []Field{{" 이름 ", ""}})
	assertStrings(t, []string{"1101000", " A : 한글 "}, ListKeys(1, 50))
}

func TestDeleteAllAndReload(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	batch := []testEntry{}
	for i := 100; i < 200; i++ {
		batch = append(batch, testEntry{strconv.Itoa(i), []Field{{"old", "discard"}}})
	}
	setTestDefinitions(cross(cur), batch)
	uassert.Equal(t, 100, GetKeyCount())
	DeleteAll(cross(cur))
	uassert.Equal(t, 0, GetKeyCount())
	assertStrings(t, []string{}, ListKeys(1, 50))
	for _, entry := range batch {
		uassert.Equal(t, len(Get(entry.Key)), 0)
		_, found := GetField(entry.Key, "old")["value"]
		uassert.False(t, found)
	}
	uassert.True(t, strings.Contains(Render(""), "No entries"))
	DeleteAll(cross(cur))
	setTestDefinition(cross(cur), "100", []Field{{"new", "replacement"}})
	fields := Get("100")
	assertFieldList(t, []Field{{"new", "replacement"}}, fields)
	uassert.Equal(t, 1, GetKeyCount())
}

func TestBatchIdempotenceAndAtomicValidation(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	entries := []testEntry{{"a", []Field{{"name", "old"}}}, {"b", []Field{{"name", "other"}}}}
	setTestDefinitions(cross(cur), entries)
	setTestDefinitions(cross(cur), entries)
	uassert.Equal(t, 2, GetKeyCount())
	for _, tc := range []struct {
		name   string
		entry  testEntry
		errMsg string
	}{
		{"duplicate entry", testEntry{"a", []Field{{"n", "v"}}}, "duplicate entry"},
		{"duplicate field", testEntry{"c", []Field{{"n", "v"}, {"n", "v"}}}, "duplicate field key"},
		{"invalid key", testEntry{"", []Field{{"n", "v"}}}, "empty entry token"},
		{"invalid field", testEntry{"c", []Field{{"\n", "v"}}}, "field key is required"},
		{"empty fields", testEntry{"c", nil}, "empty entry token"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			testing.SetRealm(testing.NewUserRealm(definitionAdmin))
			batch := []testEntry{{"a", []Field{{"name", "new"}}}, tc.entry}
			uassert.AbortsWithMessage(t, cur, tc.errMsg, func() { setTestDefinitions(cross(cur), batch) })
			value, _ := GetField("a", "name")["value"]
			uassert.Equal(t, "old", value)
			uassert.Equal(t, 2, GetKeyCount())
		})
	}
}

func TestLimitsAndMergedRecord(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	full := []Field{}
	for i := 0; i < 32; i++ {
		full = append(full, Field{strconv.Itoa(i), "v"})
	}
	setTestDefinition(cross(cur), "full", full)
	uassert.AbortsWithMessage(t, cur, "field count must be between 1 and 32", func() {
		setTestDefinition(cross(cur), "full", []Field{{"extra", "v"}})
	})
	setTestDefinition(cross(cur), "bytes", []Field{{"a", strings.Repeat("x", 16383)}})
	uassert.AbortsWithMessage(t, cur, "entry bytes exceeds 16384", func() {
		setTestDefinition(cross(cur), "bytes", []Field{{"b", ""}})
	})
	setTestDefinition(cross(cur), "bytes", []Field{{"a", "small"}, {"b", ""}})
	for _, tc := range []struct{ key, errMsg string }{
		{"", "keys and values count mismatch"}, {" \t", "key is required"}, {"x\n", "invalid key"},
		{string([]byte{255}), "invalid key"}, {strings.Repeat("가", 43), "key bytes exceeds 128"},
	} {
		uassert.AbortsWithMessage(t, cur, tc.errMsg, func() { setTestDefinition(cross(cur), tc.key, []Field{{"n", "v"}}) })
	}
	setTestDefinition(cross(cur), strings.Repeat("k", 128), []Field{{strings.Repeat("f", 128), ""}})
	uassert.AbortsWithMessage(t, cur, "field key bytes exceeds 128", func() { setTestDefinition(cross(cur), "x", []Field{{strings.Repeat("f", 129), ""}}) })
	uassert.AbortsWithMessage(t, cur, "invalid field value", func() { setTestDefinition(cross(cur), "x", []Field{{"n", string([]byte{255})}}) })
	uassert.AbortsWithMessage(t, cur, "batch count must be between 1 and 100", func() { setTestDefinitions(cross(cur), nil) })
	uassert.AbortsWithMessage(t, cur, "batch count must be between 1 and 100", func() { SetDefinitions(cross(cur), strings.Repeat("x,", 100)+"x", strings.Repeat("n=v,", 100)+"n=v") })
	total := GetKeyCount()
	batch := []testEntry{}
	for i := 0; i < 5; i++ {
		batch = append(batch, testEntry{strconv.Itoa(i), []Field{{"a", strings.Repeat("x", 16383)}}})
	}
	uassert.AbortsWithMessage(t, cur, "batch bytes exceeds 65536", func() { setTestDefinitions(cross(cur), batch) })
	uassert.Equal(t, total, GetKeyCount())
}

func TestPagination(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	assertStrings(t, []string{}, ListKeys(1, 50))
	batch := []testEntry{}
	for i := 99; i >= 0; i-- {
		batch = append(batch, testEntry{strconv.Itoa(i + 100), []Field{{"n", "v"}}})
	}
	setTestDefinitions(cross(cur), batch)
	uassert.Equal(t, 100, GetKeyCount())
	assertStrings(t, []string{"100", "101"}, ListKeys(1, 2))
	assertStrings(t, []string{"198", "199"}, ListKeys(50, 2))
	assertStrings(t, []string{}, ListKeys(51, 2))
	assertStrings(t, []string{}, ListKeys(int(9223372036854775807), 50))
	uassert.PanicsWithMessage(t, cur, "page must be positive", func() { ListKeys(0, 1) })
	uassert.PanicsWithMessage(t, cur, "count must be between 1 and 50", func() { ListKeys(1, 51) })
	keys := ListKeys(1, 1)
	keys[0] = "changed"
	assertStrings(t, []string{"100"}, ListKeys(1, 1))
}

func TestWriteAuthorityAndPayment(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	setTestDefinition(cross(cur), "kept", []Field{{"name", "preserved"}})
	operator := testutils.TestAddress("definitionOperator")
	admin.SetOperator(cross(cur), operator)
	for _, caller := range []address{testutils.TestAddress("definitionUser"), operator} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		uassert.AbortsWithMessage(t, cur, "admin access required", func() { DeleteAll(cross(cur)) })
		uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetDefinitions(cross(cur), "x", "n=v") })
	}
	testing.SetOriginCaller(definitionAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/definition_relay"))
	uassert.AbortsWithMessage(t, cur, "admin access required", func() { DeleteAll(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetDefinitions(cross(cur), "x", "n=v") })
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() { DeleteAll(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() { SetDefinitions(cross(cur), "x", "n=v") })
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, 1, GetKeyCount())
	value, found := GetField("kept", "name")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "preserved", value)
	stale := captureDefinitionRealm(cross(cur))
	uassert.PanicsWithMessage(t, cur, "spoofed realm", func() { assertCanWrite(0, stale) })
}

func assertStrings(t *testing.T, expected, actual []string) {
	t.Helper()
	if !uassert.Equal(t, len(expected), len(actual)) {
		return
	}
	for i := range expected {
		uassert.Equal(t, expected[i], actual[i])
	}
}

func assertFieldList(t *testing.T, expected []Field, actual []map[string]string) {
	t.Helper()
	if !uassert.Equal(t, len(expected), len(actual)) {
		return
	}
	for i := range expected {
		uassert.Equal(t, expected[i].Key, actual[i]["key"])
		uassert.Equal(t, expected[i].Value, actual[i]["value"])
	}
}

func captureDefinitionRealm(cur realm) realm { return cur }

func TestSetDefinitionsAndEscapedFields(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	key := "한글 😀,+&=%;"
	fieldKey := "field,+&=%;"
	value := "한글 😀\n\"\\`\x00,+&=%; } //"
	SetDefinitions(cross(cur), url.QueryEscape(key)+",1101000", url.QueryEscape(fieldKey)+"="+url.QueryEscape(value)+"&empty=,key=wooden_sword")
	got, found := GetField(key, fieldKey)["value"]
	uassert.True(t, found)
	uassert.Equal(t, value, got)
	got, found = GetField(key, "empty")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "", got)
	SetDefinitions(cross(cur), url.QueryEscape(key), "new=added")
	got, _ = GetField(key, fieldKey)["value"]
	uassert.Equal(t, value, got)
	uassert.Equal(t, 2, GetKeyCount())
	got, _ = GetField("1101000", "key")["value"]
	uassert.Equal(t, "wooden_sword", got)
	DeleteAll(cross(cur))
	SetDefinitions(cross(cur), "1101000", "fresh=value")
	_, found = GetField("1101000", "key")["value"]
	uassert.False(t, found)
}

func TestSetDefinitionsRejectsInvalidInputAtomically(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	setTestDefinition(cross(cur), "kept", []Field{{"name", "old"}})
	for _, tc := range []struct{ name, keys, values, errMsg string }{
		{"empty", "", "", "batch count must be between 1 and 100"},
		{"missing keys", "", "n=v", "keys and values count mismatch"},
		{"missing values", "x", "", "keys and values count mismatch"},
		{"short values", "kept,x", "name=new", "keys and values count mismatch"},
		{"short keys", "kept", "name=new,n=v", "keys and values count mismatch"},
		{"empty key", "kept,,x", "name=new,n=v,n=v", "empty entry token"},
		{"empty fields", "kept,x", "name=new,", "empty entry token"},
		{"trailing comma", "kept,", "name=new,", "empty entry token"},
		{"duplicate key", "kept,k%65pt", "name=new,n=v", "duplicate entry"},
		{"duplicate field", "kept", "name=new&n=1&%6E=2", "duplicate field key"},
		{"invalid escape key", "kept,%zz", "name=new,n=v", "invalid encoded key"},
		{"invalid escape value", "kept,x", "name=new,n=%zz", "invalid encoded fields"},
		{"invalid utf8 key", "kept,%FF", "name=new,n=v", "invalid key"},
		{"invalid utf8 value", "kept,x", "name=new,n=%FF", "invalid field value"},
		{"invalid field", "kept,x", "name=new,%0A=v", "field key is required"},
		{"encoded empty key", "kept,+", "name=new,n=v", "key is required"},
		{"no fields", "kept,x", "name=new,&", "field count must be between 1 and 32"},
		{"encoded limit", strings.Repeat("x", 131072), "n=v", "call bytes exceeds 131071"},
		{"count limit", strings.Repeat("x,", 100) + "last", strings.Repeat("n=v,", 100) + "n=v", "batch count must be between 1 and 100"},
		{"raw limit", "a,b,c,d,e", strings.Repeat("a="+strings.Repeat("x", 16383)+",", 4) + "a=" + strings.Repeat("x", 16383), "batch bytes exceeds 65536"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			testing.SetRealm(testing.NewUserRealm(definitionAdmin))
			uassert.AbortsWithMessage(t, cur, tc.errMsg, func() { SetDefinitions(cross(cur), tc.keys, tc.values) })
			value, found := GetField("kept", "name")["value"]
			uassert.True(t, found)
			uassert.Equal(t, "old", value)
			uassert.Equal(t, 1, GetKeyCount())
		})
	}
}

func TestSetDefinitionsBatchAndMergedLimits(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	keys, values, fields := "", "", ""
	for i := 0; i < 32; i++ {
		if i > 0 {
			fields += "&"
		}
		fields += strconv.Itoa(i) + "=value"
	}
	for i := 0; i < 100; i++ {
		if i > 0 {
			keys += ","
			values += ","
		}
		keys += strconv.Itoa(i)
		values += fields
	}
	SetDefinitions(cross(cur), keys, values)
	uassert.Equal(t, 100, GetKeyCount())
	uassert.AbortsWithMessage(t, cur, "field count must be between 1 and 32", func() {
		SetDefinitions(cross(cur), "0", "extra=value")
	})
	got := Get("0")
	uassert.Equal(t, 32, len(got))
	uassert.AbortsWithMessage(t, cur, "field count must be between 1 and 32", func() {
		SetDefinitions(cross(cur), "new", fields+"&extra=value")
	})
}

// Test fixtures use the same encoded input boundary as the importer.
type testEntry struct {
	Key    string
	Fields []Field
}

func setTestDefinition(cur realm, key string, fields []Field) {
	setTestDefinitions(cur, []testEntry{{key, fields}})
}

func setTestDefinitions(cur realm, entries []testEntry) {
	keys, values := "", ""
	for i, entry := range entries {
		if i > 0 {
			keys += ","
			values += ","
		}
		keys += url.QueryEscape(entry.Key)
		for j, field := range entry.Fields {
			if j > 0 {
				values += "&"
			}
			values += url.QueryEscape(field.Key) + "=" + url.QueryEscape(field.Value)
		}
	}
	SetDefinitions(cur, keys, values)
}

func TestNumericKeyPagination(cur realm, t *testing.T) {
	setupDefinition(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(definitionAdmin))
	huge := strings.Repeat("9", 128)
	keys := []string{"1000000", "100", "10", "2", "1", "0", "01", "00", "item:2", "item:10", "18446744073709551616", huge}
	entries := []testEntry{}
	for _, key := range keys {
		entries = append(entries, testEntry{key, []Field{{"name", key}}})
	}
	setTestDefinitions(cross(cur), entries)
	assertStrings(t, []string{"0", "00", "01", "1", "2"}, ListKeys(1, 5))
	assertStrings(t, []string{"10", "100", "1000000", "18446744073709551616", huge}, ListKeys(2, 5))
	assertStrings(t, []string{"item:10", "item:2"}, ListKeys(3, 5))
	assertStrings(t, []string{}, ListKeys(4, 5))
	for _, key := range keys {
		value, found := GetField(key, "name")["value"]
		uassert.True(t, found)
		uassert.Equal(t, key, value)
	}
	SetDefinitions(cross(cur), "2", "name=updated")
	uassert.Equal(t, len(keys), GetKeyCount())
	assertStrings(t, []string{"0", "00", "01", "1", "2"}, ListKeys(1, 5))
	DeleteAll(cross(cur))
	assertStrings(t, []string{}, ListKeys(1, 5))
}
