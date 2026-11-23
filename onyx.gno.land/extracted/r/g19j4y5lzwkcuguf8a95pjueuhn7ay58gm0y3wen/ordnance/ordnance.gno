// Package onyx is the GNO Ordnance map realm (v2).
// One labelled snapshot, loaded atomically in a single transaction.
// Districts are defined independently of plots, so empty ones render as open ground.
// Render paths: "" overview | "<district>" detail | "data/districts" | "data/plots"
package ordnance

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

type District struct {
	Name string
	X, Z int // world centre
	R    int // radius
}

type Plot struct {
	Path, District, Name, Last string
	Txs                        int
	X, Z                       int // offset from district centre
}

var (
	admin     address
	label     string
	date      string
	districts []District
	plots     []Plot
	maxTxs    int
)

const openGround = 2

func init() {
	admin = unsafe.PreviousRealm().Address()
}

func atoi(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		panic("onyx: bad number: " + s)
	}
	return n
}

// LoadSnapshot replaces the whole map in one transaction.
// districtsCSV rows: name,x,z,radius
// plotsCSV rows:     path,district,name,txs,x,z,last   (last may contain commas)
func LoadSnapshot(cur realm, snapLabel, snapDate, districtsCSV, plotsCSV string) {
	if cur.Previous().Address() != admin {
		panic("onyx: admin only")
	}

	var ds []District
	seen := map[string]bool{}
	for _, row := range strings.Split(districtsCSV, "\n") {
		row = strings.TrimSpace(row)
		if row == "" {
			continue
		}
		f := strings.Split(row, ",")
		if len(f) != 4 {
			panic("onyx: district row needs 4 fields: " + row)
		}
		name := strings.ToLower(strings.TrimSpace(f[0]))
		if seen[name] {
			panic("onyx: duplicate district " + name)
		}
		seen[name] = true
		ds = append(ds, District{name, atoi(f[1]), atoi(f[2]), atoi(f[3])})
	}
	if len(ds) == 0 {
		panic("onyx: no districts")
	}

	var ps []Plot
	mx := 0
	for _, row := range strings.Split(plotsCSV, "\n") {
		row = strings.TrimSpace(row)
		if row == "" {
			continue
		}
		f := strings.SplitN(row, ",", 7)
		if len(f) != 7 {
			panic("onyx: plot row needs 7 fields: " + row)
		}
		d := strings.ToLower(strings.TrimSpace(f[1]))
		if !seen[d] {
			panic("onyx: unknown district " + d)
		}
		txs := atoi(f[3])
		if txs < 0 {
			panic("onyx: negative txs")
		}
		if txs > mx {
			mx = txs
		}
		ps = append(ps, Plot{strings.TrimSpace(f[0]), d, strings.TrimSpace(f[2]),
			strings.TrimSpace(f[6]), txs, atoi(f[4]), atoi(f[5])})
	}

	// all parsed and validated: commit
	label, date, districts, plots, maxTxs = snapLabel, snapDate, ds, ps, mx
}

func height(txs int) int {
	if maxTxs == 0 {
		return 0
	}
	v := txs * 10000 / maxTxs
	r := 0
	for (r+1)*(r+1) <= v {
		r++
	}
	return r
}

func tier(h int) string {
	switch {
	case h >= 70:
		return "Mountain"
	case h >= 40:
		return "Ridge"
	case h >= 15:
		return "Hill"
	}
	return "Mound"
}

func in(d string) []Plot {
	var out []Plot
	for _, p := range plots {
		if p.District == d {
			out = append(out, p)
		}
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Txs > out[j-1].Txs; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func find(name string) (District, bool) {
	for _, d := range districts {
		if d.Name == name {
			return d, true
		}
	}
	return District{}, false
}

func clean(s string) string { return strings.ReplaceAll(s, ",", ";") }

func Render(path string) string {
	if len(districts) == 0 {
		return "# GNO Ordnance\n\nNo snapshot loaded yet."
	}
	switch path {
	case "":
		return overview()
	case "data/districts":
		s := "name,x,z,radius,realms\n"
		for _, d := range districts {
			s += d.Name + "," + strconv.Itoa(d.X) + "," + strconv.Itoa(d.Z) + "," +
				strconv.Itoa(d.R) + "," + strconv.Itoa(len(in(d.Name))) + "\n"
		}
		return s
	case "data/plots":
		s := "path,district,name,txs,height,tier,x,z,last\n"
		for _, p := range plots {
			d, _ := find(p.District)
			h := height(p.Txs)
			s += p.Path + "," + p.District + "," + p.Name + "," + strconv.Itoa(p.Txs) + "," +
				strconv.Itoa(h) + "," + tier(h) + "," + strconv.Itoa(d.X+p.X) + "," +
				strconv.Itoa(d.Z+p.Z) + "," + clean(p.Last) + "\n"
		}
		return s
	}
	d, ok := find(strings.ToLower(path))
	if !ok {
		return "# Not on the map\n\nNo district `" + path + "`.\n\n[Back to map](:)"
	}
	return detail(d)
}

func overview() string {
	s := "# GNO Ordnance\n\nSnapshot: **" + label + "** (" + date + ")  \n"
	s += strconv.Itoa(len(plots)) + " realms across " + strconv.Itoa(len(districts)) + " districts.\n\n"
	for _, d := range districts {
		ps := in(d.Name)
		s += "## [" + d.Name + "](:" + d.Name + ")\n"
		if len(ps) == 0 {
			s += "**Open ground**: nothing built yet.\n\n"
			continue
		}
		pk := height(ps[0].Txs)
		s += strconv.Itoa(len(ps)) + " realms, peak " + ps[0].Name + " (" + tier(pk) + ", " + strconv.Itoa(pk) + ")"
		if len(ps) <= openGround {
			s += "  \n**Open ground**: barely built."
		}
		s += "\n\n"
	}
	return s
}

func detail(d District) string {
	ps := in(d.Name)
	s := "# " + d.Name + " district\n\nSnapshot: " + label + " (" + date + ")\n\n"
	if len(ps) == 0 {
		return s + "> Open ground: no realms here yet.\n\n[Back to map](:)"
	}
	if len(ps) <= openGround {
		s += "> Open ground: only " + strconv.Itoa(len(ps)) + " realm(s).\n\n"
	}
	for _, p := range ps {
		h := height(p.Txs)
		s += "### " + p.Name + " (" + tier(h) + ", " + strconv.Itoa(h) + ")\n"
		s += strconv.Itoa(p.Txs) + " txs. " + p.Last + "  \n"
		s += "[Enter realm](/" + strings.TrimPrefix(p.Path, "gno.land/") + ")\n\n"
	}
	return s + "[Back to map](:)"
}
