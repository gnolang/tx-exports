package board

import (
	"strconv"
	"strings"

	pager "gno.land/p/g1yd9jn96nrgg8qyfkpcavxxvrp9g5u7nja3s9ex/pager/v0"
)

// self is this realm's gnoweb path. Update it if you deploy under another namespace.
const self = "/r/g1yd9jn96nrgg8qyfkpcavxxvrp9g5u7nja3s9ex/board"

// Render routes:
//
//	""                 latest reports (paginated)
//	"pkg/<pkgpath>"    version history of one package, with gas deltas
//	"report/<id>"      one full report
//	"badge/<pkgpath>"  one-line markdown summary for READMEs
//	"api/..."          JSON for dApps (see json.gno)
func Render(path string) string {
	base := pager.Base(path)
	switch {
	case base == "":
		return renderHome(path)
	case strings.HasPrefix(base, "api/"):
		return renderAPI(strings.TrimPrefix(base, "api/"), path)
	case strings.HasPrefix(base, "pkg/"):
		return renderPkg(strings.TrimPrefix(base, "pkg/"), path)
	case strings.HasPrefix(base, "report/"):
		id, err := strconv.Atoi(strings.TrimPrefix(base, "report/"))
		if err != nil {
			return "# Not found\n"
		}
		return renderReport(id)
	case strings.HasPrefix(base, "badge/"):
		return renderBadge(strings.TrimPrefix(base, "badge/"))
	}
	return "# Not found\n"
}

func renderHome(path string) string {
	var b strings.Builder
	b.WriteString("# Assayer\n\n")
	b.WriteString("Pre-deploy audits of Gno realms: logic bugs, state layout, and measured gas & storage cost.\n\n")
	b.WriteString("**" + strconv.Itoa(Count()) + "** reports · **" + strconv.Itoa(PackageCount()) + "** packages\n\n")

	offset, limit := pager.Parse(path)
	page := pager.Of(reports, offset, limit, true)
	if len(page.Items) == 0 {
		b.WriteString("_No reports yet. Run `assayer audit` and `assayer submit`._\n")
		return b.String()
	}
	b.WriteString("| # | Package | v | Score | Worst function | Height |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	for _, it := range page.Items {
		r := it.Value.(*Report)
		b.WriteString("| [" + strconv.Itoa(r.ID) + "](" + self + ":report/" + strconv.Itoa(r.ID) + ") | ")
		b.WriteString("[" + r.PkgPath + "](" + self + ":pkg/" + r.PkgPath + ") | ")
		b.WriteString(strconv.Itoa(r.Version) + " | ")
		b.WriteString(scoreLabel(r.Overall) + " | ")
		b.WriteString(worstFunc(r) + " | ")
		b.WriteString(strconv.FormatInt(r.Height, 10) + " |\n")
	}
	b.WriteString(page.Nav(""))
	return b.String()
}

func renderPkg(pkgPath, path string) string {
	versions := versionsOf(pkgPath)
	if versions == nil {
		return "# " + pkgPath + "\n\n_No reports for this package._\n"
	}
	var b strings.Builder
	b.WriteString("# " + pkgPath + "\n\n")
	b.WriteString(renderBadge(pkgPath) + "\n\n")

	offset, limit := pager.Parse(path)
	page := pager.Of(versions, offset, limit, true)
	for _, it := range page.Items {
		r := it.Value.(*Report)
		b.WriteString("## v" + strconv.Itoa(r.Version) + " · " + scoreLabel(r.Overall))
		b.WriteString(" · [report " + strconv.Itoa(r.ID) + "](" + self + ":report/" + strconv.Itoa(r.ID) + ")\n\n")
		b.WriteString("source `" + r.SourceHash[:12] + "` · height " + strconv.FormatInt(r.Height, 10) + "\n\n")

		var prev *Report
		if r.Version > 1 {
			if v := versions.Get(pad(r.Version - 1)); v != nil {
				prev = v.(*Report)
			}
		}
		if len(r.Funcs) > 0 {
			b.WriteString("| Function | Complexity | Gas @ n | Δ vs previous |\n|---|---|---|---|\n")
			for _, f := range r.Funcs {
				b.WriteString("| " + f.Name + " | " + f.Class + " | " + fmtGas(f.GasAtMaxN) + " @ " + strconv.Itoa(f.MaxN) + " | ")
				b.WriteString(delta(prev, f) + " |\n")
			}
			b.WriteString("\n")
		}
	}
	b.WriteString(page.Nav("pkg/" + pkgPath))
	return b.String()
}

func renderReport(id int) string {
	r := GetReport(id)
	if r == nil {
		return "# Not found\n"
	}
	var b strings.Builder
	b.WriteString("# Report " + strconv.Itoa(r.ID) + "\n\n")
	b.WriteString("[" + r.PkgPath + "](" + self + ":pkg/" + r.PkgPath + ") · version " + strconv.Itoa(r.Version) + "\n\n")
	b.WriteString("- source sha256: `" + r.SourceHash + "`\n")
	b.WriteString("- submitted by `" + r.Submitter.String() + "` at height " + strconv.FormatInt(r.Height, 10) + "\n")
	if r.Tool != "" {
		b.WriteString("- tool: " + r.Tool + "\n")
	}
	b.WriteString("\n| Overall | Security | State | Cost | Quality |\n|---|---|---|---|---|\n")
	b.WriteString("| " + scoreLabel(r.Overall) + " | " + strconv.Itoa(r.Security) + " | " + strconv.Itoa(r.State) +
		" | " + strconv.Itoa(r.Cost) + " | " + strconv.Itoa(r.Quality) + " |\n\n")

	if len(r.Funcs) > 0 {
		b.WriteString("## Measured cost\n\n")
		b.WriteString("| Function | Complexity | n | Gas | Gas per extra item | Storage Δ (bytes) |\n|---|---|---|---|---|---|\n")
		for _, f := range r.Funcs {
			b.WriteString("| " + f.Name + " | " + f.Class + " | " + strconv.Itoa(f.MaxN) + " | " + fmtGas(f.GasAtMaxN) +
				" | " + fmtGas(f.GasPerItem) + " | " + strconv.FormatInt(f.StorageBytes, 10) + " |\n")
		}
		b.WriteString("\n")
	}
	if len(r.Findings) > 0 {
		b.WriteString("## Findings\n\n| Rule | Severity | Location |\n|---|---|---|\n")
		for _, f := range r.Findings {
			b.WriteString("| " + f.Rule + " | " + f.Severity + " | " + f.File + ":" + strconv.Itoa(f.Line) + " |\n")
		}
		b.WriteString("\nRun `assayer explain <rule>` for the why and the fix.\n")
	}
	return b.String()
}

func renderBadge(pkgPath string) string {
	r := Latest(pkgPath)
	if r == nil {
		return "Assayer: not measured"
	}
	return "**Assayer " + strconv.Itoa(r.Overall) + "/100** · worst: " + worstFunc(r) +
		" · v" + strconv.Itoa(r.Version)
}

// ---- helpers ----

var classRank = map[string]int{
	"?": 0, "O(1)": 1, "O(log n)": 2, "O(n)": 3, "O(n log n)": 4, "O(n^2)": 5,
}

func worstFunc(r *Report) string {
	if len(r.Funcs) == 0 {
		return "—"
	}
	worst := r.Funcs[0]
	for _, f := range r.Funcs[1:] {
		if classRank[f.Class] > classRank[worst.Class] ||
			(classRank[f.Class] == classRank[worst.Class] && f.GasAtMaxN > worst.GasAtMaxN) {
			worst = f
		}
	}
	return worst.Name + " " + worst.Class
}

func scoreLabel(s int) string {
	mark := "🟢"
	if s < 50 {
		mark = "🔴"
	} else if s < 80 {
		mark = "🟡"
	}
	return mark + " " + strconv.Itoa(s)
}

func delta(prev *Report, f FuncBench) string {
	if prev == nil {
		return "—"
	}
	for _, p := range prev.Funcs {
		if p.Name != f.Name {
			continue
		}
		if p.MaxN != f.MaxN || p.GasAtMaxN == 0 {
			return "n changed"
		}
		pct := (f.GasAtMaxN - p.GasAtMaxN) * 100 / p.GasAtMaxN
		switch {
		case pct > 0:
			return "▲ +" + strconv.FormatInt(pct, 10) + "%"
		case pct < 0:
			return "▼ " + strconv.FormatInt(pct, 10) + "%"
		}
		return "="
	}
	return "new"
}

func fmtGas(g int64) string {
	switch {
	case g >= 1000000:
		return strconv.FormatInt(g/1000000, 10) + "." + strconv.FormatInt((g%1000000)/100000, 10) + "M"
	case g >= 1000:
		return strconv.FormatInt(g/1000, 10) + "." + strconv.FormatInt((g%1000)/100, 10) + "k"
	}
	return strconv.FormatInt(g, 10)
}
