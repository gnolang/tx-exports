package hello_verify_b

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
)

type CallRecord struct {
	Seq           int
	Tag           string
	PrevAddr      string
	PrevPkgPath   string
	PrevIsUser    bool
	PrevIsEOA     bool
	OriginCaller  string
	BlockHeight   int64
	BlockTimeUnix int64
}

var (
	realmAddr address
	records   []CallRecord
)

func init(cur realm) {
	realmAddr = cur.Address()
}

// RecordCaller records caller identity (cur.Previous vs unsafe.OriginCaller)
// and deterministic block timestamp/height. Callable both directly by an EOA
// and via cross-realm call from hello_verify_a.
func RecordCaller(cur realm, tag string) string {
	prev := cur.Previous()
	origin := unsafe.OriginCaller()
	rec := CallRecord{
		Seq:           len(records) + 1,
		Tag:           tag,
		PrevAddr:      prev.Address().String(),
		PrevPkgPath:   prev.PkgPath(),
		PrevIsUser:    prev.IsUser(),
		PrevIsEOA:     prev.IsUserCall(),
		OriginCaller:  origin.String(),
		BlockHeight:   runtime.ChainHeight(),
		BlockTimeUnix: time.Now().Unix(),
	}
	records = append(records, rec)
	return formatRecord(rec)
}

func RecordCount() int {
	return len(records)
}

func LastRecord() string {
	if len(records) == 0 {
		return ""
	}
	return formatRecord(records[len(records)-1])
}

func formatRecord(r CallRecord) string {
	return "#" + strconv.Itoa(r.Seq) +
		" tag=" + r.Tag +
		" prevAddr=" + r.PrevAddr +
		" prevPkg=" + r.PrevPkgPath +
		" prevIsUser=" + strconv.FormatBool(r.PrevIsUser) +
		" prevIsEOA=" + strconv.FormatBool(r.PrevIsEOA) +
		" origin=" + r.OriginCaller +
		" height=" + strconv.FormatInt(r.BlockHeight, 10) +
		" unix=" + strconv.FormatInt(r.BlockTimeUnix, 10)
}

func Render(path string) string {
	if path == "json/state" {
		var sb strings.Builder
		sb.WriteString(`{"realm":"hello_verify_b","addr":"` + realmAddr.String() + `","count":` + strconv.Itoa(len(records)) + `,"records":[`)
		for i, r := range records {
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"seq":` + strconv.Itoa(r.Seq) +
				`,"tag":"` + escapeJSON(r.Tag) +
				`","prevAddr":"` + r.PrevAddr +
				`","prevPkg":"` + escapeJSON(r.PrevPkgPath) +
				`","prevIsUser":` + strconv.FormatBool(r.PrevIsUser) +
				`,"prevIsEOA":` + strconv.FormatBool(r.PrevIsEOA) +
				`,"origin":"` + r.OriginCaller +
				`","height":` + strconv.FormatInt(r.BlockHeight, 10) +
				`,"unix":` + strconv.FormatInt(r.BlockTimeUnix, 10) + `}`)
		}
		sb.WriteString("]}")
		return sb.String()
	}

	var sb strings.Builder
	sb.WriteString("# hello_verify_b (Langkah 0 Scratch)\n\n")
	sb.WriteString("- Realm Address: `" + realmAddr.String() + "`\n")
	sb.WriteString("- Total Recorded Calls: `" + strconv.Itoa(len(records)) + "`\n\n")
	sb.WriteString("## Call Records\n\n")
	if len(records) == 0 {
		sb.WriteString("_No calls recorded yet._\n")
	} else {
		for _, r := range records {
			sb.WriteString("- `" + formatRecord(r) + "`\n")
		}
	}
	return sb.String()
}

func escapeJSON(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}
