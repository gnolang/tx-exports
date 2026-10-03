package golf

import (
	"strconv"
	"strings"
)

// How golf's rows are kept in store: strings, never golf's own types (a value
// of a realm's type kept in another realm would carry this realm's methods into
// it, and would not outlive these rules). Each is its format's version, then
// its fields, each as its length, ":" and itself (store's own rows are so): a
// row reads back by its lengths, not by a scan of every byte (a scan, as
// strings.Split, costs several times more gas), whatever its fields hold. A
// later version of the rules reads every format ever written, row by row.
const format = "1"

func join(fs ...string) string {
	var sb strings.Builder
	sb.WriteString("1:" + format)
	for _, f := range fs {
		sb.WriteString(strconv.Itoa(len(f)) + ":" + f)
	}
	return sb.String()
}

// fields is a row's fields, its format checked: n of them, or it panics.
func fields(s, what string, n int) []string {
	f := make([]string, 0, n+1)
	for rest := s; len(rest) > 0; {
		i, l := 0, 0
		for i < len(rest) && i < 6 && rest[i] >= '0' && rest[i] <= '9' {
			l = l*10 + int(rest[i]-'0')
			i++
		}
		if i == 0 || i == len(rest) || rest[i] != ':' || len(rest)-i-1 < l || len(f) > n {
			panic("golf: a " + what + " not as golf keeps it: " + strconv.Quote(s))
		}
		f = append(f, rest[i+1:i+1+l])
		rest = rest[i+1+l:]
	}
	if len(f) != n+1 || f[0] != format {
		panic("golf: a " + what + " not as golf keeps it: " + strconv.Quote(s))
	}
	return f[1:]
}

func itoa(n int) string      { return strconv.Itoa(n) }
func i64(n int64) string     { return strconv.FormatInt(n, 10) }
func ftoa(x float64) string  { return strconv.FormatFloat(x, 'g', -1, 64) } // (exact: it reads back to the same float)
func btoa(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func atoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("golf: a number not as golf keeps it: " + strconv.Quote(s))
	}
	return n
}

func atoi64(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("golf: a number not as golf keeps it: " + strconv.Quote(s))
	}
	return n
}

func atof(s string) float64 {
	x, err := strconv.ParseFloat(s, 64)
	if err != nil {
		panic("golf: a number not as golf keeps it: " + strconv.Quote(s))
	}
	return x
}

// --- a version of a hole -------------------------------------------------------

func encodeEntry(e *entry) string {
	out := []string{"", "", "", "", ""} // never archived: no drain
	if e.out != nil {
		out = []string{"1", e.out.from[assisted], e.out.from[pro], btoa(e.out.done[assisted]), btoa(e.out.done[pro])}
	}
	return join(append([]string{e.id, e.name, itoa(e.par), e.world, ftoa(e.order), btoa(e.official),
		e.slot, itoa(e.version), e.by.String(), i64(e.height), e.sha, e.note,
		itoa(e.plays), itoa(e.best), itoa(e.proBest), e.bestBy.String(), e.proBestBy.String(), e.next}, out...)...)
}

func decodeEntry(s string) *entry {
	f := fields(s, "hole", 23)
	e := &entry{id: f[0], name: f[1], par: atoi(f[2]), world: f[3], order: atof(f[4]), official: f[5] == "1",
		slot: f[6], version: atoi(f[7]), by: address(f[8]), height: atoi64(f[9]), sha: f[10], note: f[11],
		plays: atoi(f[12]), best: atoi(f[13]), proBest: atoi(f[14]), bestBy: address(f[15]), proBestBy: address(f[16]), next: f[17]}
	if f[18] == "1" {
		e.out = &draining{from: [modes]string{f[19], f[20]}, done: [modes]bool{f[21] == "1", f[22] == "1"}}
	}
	return e
}

// --- a round under way ---------------------------------------------------------

func encodeRound(r *round) string {
	return join(ftoa(r.bx), ftoa(r.by), ftoa(r.fx), ftoa(r.fy), itoa(r.strokes), i64(r.period), r.shots, itoa(r.mode))
}

func decodeRound(s string) *round {
	f := fields(s, "round", 8)
	return &round{bx: atof(f[0]), by: atof(f[1]), fx: atof(f[2]), fy: atof(f[3]), strokes: atoi(f[4]), period: atoi64(f[5]), shots: f[6], mode: atoi(f[7])}
}

// --- a course standing ---------------------------------------------------------

func encodeRow(r *row) string {
	return join(r.player, itoa(r.holes), itoa(r.strokes), itoa(r.par), i64(r.height))
}

func decodeRow(s string) *row {
	f := fields(s, "standing", 5)
	return &row{player: f[0], holes: atoi(f[1]), strokes: atoi(f[2]), par: atoi(f[3]), height: atoi64(f[4])}
}
