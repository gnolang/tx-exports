package board

import (
	"strconv"
	"strings"

	pager "gno.land/p/g1yd9jn96nrgg8qyfkpcavxxvrp9g5u7nja3s9ex/pager/v0"
)

// JSON routes for dApps (read with vm/qrender, no gnoweb needed):
//
//	"api/stats"                      {"reports":n,"packages":m}
//	"api/reports?page=1&size=20"     newest reports, summaries only
//	"api/report/<id>"                one full report
//	"api/pkg/<pkgpath>?page=1"       version history of a package, newest first
//
// Every list is paginated with pager, so no route walks the whole board.
func renderAPI(route, path string) string {
	switch {
	case route == "stats":
		return `{"reports":` + strconv.Itoa(reports.Size()) + `,"packages":` + strconv.Itoa(byPkg.Size()) + `}`
	case route == "reports":
		offset, limit := pager.Parse(path)
		page := pager.Of(reports, offset, limit, true)
		var b strings.Builder
		writePageHead(&b, page)
		for i, it := range page.Items {
			if i > 0 {
				b.WriteByte(',')
			}
			if r, ok := it.Value.(*Report); ok {
				writeReport(&b, r, false)
			}
		}
		b.WriteString("]}")
		return b.String()
	case strings.HasPrefix(route, "report/"):
		id, err := strconv.Atoi(strings.TrimPrefix(route, "report/"))
		if err != nil {
			return `{"error":"bad id"}`
		}
		r := GetReport(id)
		if r == nil {
			return `{"error":"not found"}`
		}
		var b strings.Builder
		writeReport(&b, r, true)
		return b.String()
	case strings.HasPrefix(route, "pkg/"):
		versions := versionsOf(strings.TrimPrefix(route, "pkg/"))
		if versions == nil {
			return `{"error":"not found"}`
		}
		offset, limit := pager.Parse(path)
		page := pager.Of(versions, offset, limit, true)
		var b strings.Builder
		writePageHead(&b, page)
		for i, it := range page.Items {
			if i > 0 {
				b.WriteByte(',')
			}
			if r, ok := it.Value.(*Report); ok {
				writeReport(&b, r, true)
			}
		}
		b.WriteString("]}")
		return b.String()
	}
	return `{"error":"unknown route"}`
}

func writePageHead(b *strings.Builder, p pager.Page) {
	b.WriteString(`{"total":` + strconv.Itoa(p.Total) + `,"offset":` + strconv.Itoa(p.Offset) +
		`,"limit":` + strconv.Itoa(p.Limit) + `,"items":[`)
}

func writeReport(b *strings.Builder, r *Report, full bool) {
	b.WriteString(`{"id":` + strconv.Itoa(r.ID))
	b.WriteString(`,"pkgpath":` + jstr(r.PkgPath))
	b.WriteString(`,"version":` + strconv.Itoa(r.Version))
	b.WriteString(`,"sourceHash":` + jstr(r.SourceHash))
	b.WriteString(`,"tool":` + jstr(r.Tool))
	b.WriteString(`,"submitter":` + jstr(r.Submitter.String()))
	b.WriteString(`,"height":` + strconv.FormatInt(r.Height, 10))
	b.WriteString(`,"scores":{"overall":` + strconv.Itoa(r.Overall) + `,"security":` + strconv.Itoa(r.Security) +
		`,"state":` + strconv.Itoa(r.State) + `,"cost":` + strconv.Itoa(r.Cost) + `,"quality":` + strconv.Itoa(r.Quality) + `}`)
	b.WriteString(`,"worst":` + jstr(worstFunc(r)))
	b.WriteString(`,"counts":{`)
	counts := map[string]int{}
	for _, f := range r.Findings {
		counts[f.Severity]++
	}
	first := true
	for _, s := range []string{"critical", "high", "medium", "low", "info"} {
		if counts[s] == 0 {
			continue
		}
		if !first {
			b.WriteByte(',')
		}
		first = false
		b.WriteString(jstr(s) + ":" + strconv.Itoa(counts[s]))
	}
	b.WriteString("}")
	if full {
		b.WriteString(`,"funcs":[`)
		for i, f := range r.Funcs {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"name":` + jstr(f.Name) + `,"class":` + jstr(f.Class) + `,"maxN":` + strconv.Itoa(f.MaxN) +
				`,"gasAtMaxN":` + strconv.FormatInt(f.GasAtMaxN, 10) + `,"gasPerItem":` + strconv.FormatInt(f.GasPerItem, 10) +
				`,"storageBytes":` + strconv.FormatInt(f.StorageBytes, 10) + `}`)
		}
		b.WriteString(`],"findings":[`)
		for i, f := range r.Findings {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"rule":` + jstr(f.Rule) + `,"severity":` + jstr(f.Severity) + `,"file":` + jstr(f.File) +
				`,"line":` + strconv.Itoa(f.Line) + `}`)
		}
		b.WriteString("]")
	}
	b.WriteString("}")
}

const hexDigits = "0123456789abcdef"

// jstr encodes s as a JSON string.
func jstr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				b.WriteByte(hexDigits[c>>4])
				b.WriteByte(hexDigits[c&15])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
