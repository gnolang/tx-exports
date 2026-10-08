// Package store holds GnoRadio's string codecs: records (fields behind a
// length header, read and changed without decoding), packed id lists (9
// bytes per id, sorted, JSON-ready), base-64 fixed-width numbers, the 8-digit
// keys and page rows of the data realm, and the Ops builder of data.Batch.
// It keeps no state: every realm stores these strings in the data realm.
package store

import "strconv"

// ---- Records: fields behind a length header, sliced without scanning ----

// In the VM every byte a loop touches costs gas (strings.Split of a 200-byte
// record is about 2M gas). A record starts with the field count and each
// field's length (base-64 digits), so reading a field is a few slices.

// Digits are the base-64 digits of record headers and of Num and Fixed,
// ordered so that fixed-width numbers sort as their values do.
const Digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

const digits = Digits

// dec decodes record headers, dec64 the numbers of Num: one table each
// spares a conversion per digit.
var (
	dec   [128]int
	dec64 [128]int64
)

func init() {
	for i := 0; i < len(digits); i++ {
		dec[digits[i]], dec64[digits[i]] = i, int64(i)
	}
}

// Num reads the w-digit base-64 number at position at of s (one expression
// for the usual widths: every VM step costs gas).
func Num(s string, at, w int) int64 {
	switch w {
	case 1:
		return dec64[s[at]]
	case 2:
		return dec64[s[at]]<<6 | dec64[s[at+1]]
	case 4:
		return dec64[s[at]]<<18 | dec64[s[at+1]]<<12 | dec64[s[at+2]]<<6 | dec64[s[at+3]]
	case 6:
		return dec64[s[at]]<<30 | dec64[s[at+1]]<<24 | dec64[s[at+2]]<<18 | dec64[s[at+3]]<<12 | dec64[s[at+4]]<<6 | dec64[s[at+5]]
	}
	var v int64
	for i := at; i < at+w; i++ {
		v = v<<6 | dec64[s[i]]
	}
	return v
}

// Fixed writes v in w base-64 digits.
func Fixed(v int64, w int) string { return string(AppendFixed(make([]byte, 0, w), v, w)) }

// AppendFixed appends v in w base-64 digits to b (one append for the usual
// widths). It panics when v does not fit.
func AppendFixed(b []byte, v int64, w int) []byte {
	if v < 0 || v>>(6*w) != 0 {
		panic("store: number out of range")
	}
	switch w {
	case 1:
		return append(b, digits[v])
	case 2:
		return append(b, digits[v>>6], digits[v&63])
	case 4:
		return append(b, digits[v>>18], digits[v>>12&63], digits[v>>6&63], digits[v&63])
	case 6:
		return append(b, digits[v>>30], digits[v>>24&63], digits[v>>18&63], digits[v>>12&63], digits[v>>6&63], digits[v&63])
	}
	for i := w - 1; i >= 0; i-- {
		b = append(b, digits[v>>(6*i)&63])
	}
	return b
}

// MaxField is the longest field a record holds (3 base-64 digits).
const MaxField = 1<<18 - 1

// Rec packs fields into a record (at most 63 fields).
func Rec(fs ...string) string {
	if len(fs) > 63 {
		panic("store: too many fields")
	}
	h := make([]byte, 1, 1+3*len(fs))
	h[0] = digits[len(fs)]
	body := make([]byte, 0, 64)
	for _, f := range fs {
		n := len(f)
		if n > MaxField {
			panic("store: field too long")
		}
		h = append(h, digits[n>>12&63], digits[n>>6&63], digits[n&63])
		body = append(body, f...)
	}
	return string(h) + string(body)
}

func fieldLen(rec string, i int) int {
	return dec[rec[1+3*i]]<<12 | dec[rec[2+3*i]]<<6 | dec[rec[3+3*i]]
}

// Fields unpacks a record.
func Fields(rec string) []string {
	n := dec[rec[0]]
	out := make([]string, n)
	p := 1 + 3*n
	for i := 0; i < n; i++ {
		l := fieldLen(rec, i)
		out[i] = rec[p : p+l]
		p += l
	}
	return out
}

// Field returns field i of a record ("" past the last field).
func Field(rec string, i int) string {
	n := dec[rec[0]]
	if i >= n {
		return ""
	}
	p := 1 + 3*n
	for k := 0; k < i; k++ {
		p += fieldLen(rec, k)
	}
	return rec[p : p+fieldLen(rec, i)]
}

// With returns rec with field i replaced by v, without decoding the record.
func With(rec string, i int, v string) string {
	n := dec[rec[0]]
	if i < 0 || i >= n || len(v) > MaxField {
		panic("store: bad field")
	}
	p := 1 + 3*n
	for k := 0; k < i; k++ {
		p += fieldLen(rec, k)
	}
	l := len(v)
	h := string([]byte{digits[l>>12&63], digits[l>>6&63], digits[l&63]})
	return rec[:1+3*i] + h + rec[4+3*i:p] + v + rec[p+fieldLen(rec, i):]
}

// Append returns rec with v added as its last field, without decoding the
// record ("" is a record of no fields).
func Append(rec, v string) string {
	if rec == "" {
		return Rec(v)
	}
	n := dec[rec[0]]
	if n >= 63 || len(v) > MaxField {
		panic("store: bad field")
	}
	l := len(v)
	h := string([]byte{digits[n+1], digits[l>>12&63], digits[l>>6&63], digits[l&63]})
	return h[:1] + rec[1:1+3*n] + h[1:] + rec[1+3*n:] + v
}

// ---- Id lists: W bytes per id ("     123,"), sortable and JSON-ready ----

// W is the width of one id in a list (ids up to 99,999,999). The padding is
// spaces and the separator a comma, so "[" + list without its last comma +
// "]" is already a JSON array: exporting a list costs no per-id work.
const W = 9

// Enc writes one id of a list.
func Enc(id int) string {
	if id < 0 || id > 99999999 {
		panic("store: id out of range")
	}
	s := strconv.Itoa(id)
	return "        "[len(s):] + s + ","
}

// At returns the i-th id of a list.
func At(list string, i int) int {
	n := 0
	for k := i * W; k < i*W+W-1; k++ {
		if c := list[k]; c != ' ' {
			n = n*10 + int(c-'0')
		}
	}
	return n
}

// Count is the number of ids in a list.
func Count(list string) int { return len(list) / W }

// JSON returns a list as a JSON array.
func JSON(list string) string {
	if list == "" {
		return "[]"
	}
	return "[" + list[:len(list)-1] + "]"
}

// Ints decodes a list.
func Ints(list string) []int {
	out := make([]int, 0, Count(list))
	for i := 0; i < Count(list); i++ {
		out = append(out, At(list, i))
	}
	return out
}

// Pack encodes ids in their order.
func Pack(ids []int) string {
	b := make([]byte, 0, W*len(ids))
	for _, id := range ids {
		b = append(b, Enc(id)...)
	}
	return string(b)
}

// Page returns up to limit ids from offset, from the end when desc.
func Page(list string, offset, limit int, desc bool) []int {
	n := Count(list)
	var out []int
	for k := offset; k >= 0 && k < n && len(out) < limit; k++ {
		i := k
		if desc {
			i = n - 1 - k
		}
		out = append(out, At(list, i))
	}
	return out
}

// find returns the position of id in a sorted list, or where it goes.
func find(list string, id int) (int, bool) {
	lo, hi := 0, Count(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if At(list, mid) < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < Count(list) && At(list, lo) == id
}

// Add inserts id into a sorted list; false if already there.
func Add(sorted string, id int) (string, bool) {
	i, ok := find(sorted, id)
	if ok {
		return sorted, false
	}
	return sorted[:i*W] + Enc(id) + sorted[i*W:], true
}

// Remove deletes id from a sorted list; false if absent.
func Remove(sorted string, id int) (string, bool) {
	i, ok := find(sorted, id)
	if !ok {
		return sorted, false
	}
	return sorted[:i*W] + sorted[i*W+W:], true
}

// ---- Keys, page rows and batch ops for the data realm ----

// Pad writes a number as an 8-digit key, so keys sort as numbers do.
func Pad(n int) string {
	if n < 0 || n > 99999999 {
		panic("store: key number out of range")
	}
	s := strconv.Itoa(n)
	return "00000000"[len(s):] + s
}

// TimeKey writes a unix time as a 12-digit key, so keys sort as times do.
func TimeKey(t int64) string {
	s := strconv.FormatInt(t, 10)
	return "000000000000"[len(s):] + s
}

// Slot is where record id (from 1) of a chunked collection lives: the key
// of its chunk of size records and its index there.
func Slot(id, size int) (string, int) { return Pad((id - 1) / size), (id - 1) % size }

// Limit is a page size: n, or max when n is out of 1..max.
func Limit(n, max int) int {
	if n < 1 || n > max {
		return max
	}
	return n
}

// Row encodes one key and value of a page: "len:key" + "len:value".
func Row(k, v string) string {
	return strconv.Itoa(len(k)) + ":" + k + strconv.Itoa(len(v)) + ":" + v
}

// Rows decodes a page of Row strings into its keys and values.
func Rows(page string) (keys, values []string) {
	for page != "" {
		var k, v string
		k, page = cut(page)
		v, page = cut(page)
		keys, values = append(keys, k), append(values, v)
	}
	return keys, values
}

// cut reads one "len:bytes" item off the front of s.
func cut(s string) (item, rest string) {
	i, n := 0, 0
	for i < len(s) && i < 6 && s[i] >= '0' && s[i] <= '9' {
		n = n*10 + int(s[i]-'0') // the length, read as it is scanned
		i++
	}
	if i == 0 || i == len(s) || s[i] != ':' {
		panic("store: bad row")
	}
	if n > len(s)-i-1 {
		panic("store: bad row")
	}
	return s[i+1 : i+1+n], s[i+1+n:]
}

// Batch op names: an op is four strings (name, collection, key, value).
const (
	OpSet = "set"
	OpDel = "del"
)

// Ops builds the argument of data.Batch: ops = ops.Set(c, k, v).
type Ops []string

// Set adds a write of v at key k of collection c.
func (o Ops) Set(c, k, v string) Ops { return append(o, OpSet, c, k, v) }

// Del adds a removal of key k of collection c.
func (o Ops) Del(c, k string) Ops { return append(o, OpDel, c, k, "") }
