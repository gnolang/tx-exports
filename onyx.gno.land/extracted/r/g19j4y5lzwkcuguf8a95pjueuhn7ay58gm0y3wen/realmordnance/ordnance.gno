// Package realmordnance publishes labelled maps of Gno realms.
// Uploads are staged in batches; Publish swaps the complete map into view.
package realmordnance

import (
    "chain/runtime/unsafe"
    "strconv"
    "strings"
)

type District struct {
    Name string
    X, Z, Radius int
}

type Plot struct {
    Path, District, Name, Last string
    Calls, Callers, Blocks int
    X, Z int // offsets from district centre
}

type Snapshot struct {
    Label, Date string
    Districts []District
    Plots []Plot
    MaxCalls int
}

var owner address
var active Snapshot
var pending Snapshot
var staging bool

const maxDistricts = 40
const maxPlots = 2000
const maxBatch = 80

func init() { owner = unsafe.PreviousRealm().Address() }

func admin(cur realm) {
    if cur.Previous().Address() != owner { panic("realmordnance: owner only") }
}

func number(s string) int {
    v, err := strconv.Atoi(strings.TrimSpace(s))
    if err != nil { panic("realmordnance: invalid number") }
    return v
}

func validName(s string) bool {
    if s == "" || len(s) > 80 { return false }
    for _, c := range s {
        if c == ',' || c == '\n' || c == '\r' { return false }
    }
    return true
}

func districtExists(ds []District, name string) bool {
    for _, d := range ds { if d.Name == name { return true } }
    return false
}

func plotExists(ps []Plot, path string) bool {
    for _, p := range ps { if p.Path == path { return true } }
    return false
}

// Begin starts a replacement snapshot. The previous published map stays visible.
func Begin(cur realm, label, date string) {
    admin(cur)
    if !validName(label) || !validName(date) { panic("realmordnance: invalid snapshot label") }
    pending = Snapshot{Label: label, Date: date}
    staging = true
}

// AddDistricts accepts name,x,z,radius rows separated by newlines.
func AddDistricts(cur realm, csv string) {
    admin(cur)
    if !staging { panic("realmordnance: call Begin first") }
    ds := append([]District(nil), pending.Districts...)
    count := 0
    for _, row := range strings.Split(strings.TrimSpace(csv), "\n") {
        fields := strings.Split(strings.TrimSpace(row), ",")
        if len(fields) != 4 { panic("realmordnance: district requires 4 columns") }
        name := strings.ToLower(strings.TrimSpace(fields[0]))
        x, z, radius := number(fields[1]), number(fields[2]), number(fields[3])
        if !validName(name) || districtExists(ds, name) || radius < 10 || radius > 10000 || x < -100000 || x > 100000 || z < -100000 || z > 100000 {
            panic("realmordnance: invalid district")
        }
        ds = append(ds, District{name, x, z, radius})
        count++
        if count > maxBatch || len(ds) > maxDistricts { panic("realmordnance: too many districts") }
    }
    pending.Districts = ds
}

// AddPlots accepts path,district,name,calls,callers,blocks,x,z,last rows.
// Values cannot contain commas or newlines. Activity is supplied by the scanner,
// not asserted by this realm; the snapshot label records its provenance.
func AddPlots(cur realm, csv string) {
    admin(cur)
    if !staging { panic("realmordnance: call Begin first") }
    ps := append([]Plot(nil), pending.Plots...)
    peak, count := pending.MaxCalls, 0
    for _, row := range strings.Split(strings.TrimSpace(csv), "\n") {
        f := strings.Split(strings.TrimSpace(row), ",")
        if len(f) != 9 { panic("realmordnance: plot requires 9 columns") }
        path, district, name := strings.TrimSpace(f[0]), strings.ToLower(strings.TrimSpace(f[1])), strings.TrimSpace(f[2])
        calls, callers, blocks, x, z := number(f[3]), number(f[4]), number(f[5]), number(f[6]), number(f[7])
        last := strings.TrimSpace(f[8])
        if !strings.HasPrefix(path, "gno.land/r/") || (len(path) > 200 || strings.ContainsAny(path, ",\n\r")) || !validName(name) || !validName(last) ||
            !districtExists(pending.Districts, district) || plotExists(ps, path) || calls < 0 || callers < 0 || blocks < 0 ||
            x < -10000 || x > 10000 || z < -10000 || z > 10000 {
            panic("realmordnance: invalid plot")
        }
        ps = append(ps, Plot{path, district, name, last, calls, callers, blocks, x, z})
        if calls > peak { peak = calls }
        count++
        if count > maxBatch || len(ps) > maxPlots { panic("realmordnance: too many plots") }
    }
    pending.Plots, pending.MaxCalls = ps, peak
}

// Publish atomically replaces the visible snapshot after every batch is valid.
func Publish(cur realm) {
    admin(cur)
    if !staging || len(pending.Districts) == 0 { panic("realmordnance: incomplete snapshot") }
    active = pending
    pending = Snapshot{}
    staging = false
}

func Height(calls int) int {
    if active.MaxCalls == 0 || calls == 0 { return 0 }
    // Integer square-root scaling makes quiet realms visible.
    score := calls * 10000 / active.MaxCalls
    h := 0
    for (h+1)*(h+1) <= score { h++ }
    return h
}

func Settlement(p Plot) string {
    if p.Callers >= 20 && p.Blocks >= 15 { return "Castle" }
    if p.Callers >= 5 && p.Blocks >= 3 { return "Village" }
    return "Cottage"
}

func n(i int) string { return strconv.Itoa(i) }

func Render(path string) string {
    if len(active.Districts) == 0 { return "# Realm Ordnance\n\nNo published snapshot yet." }
    switch path {
    case "data/districts":
        s := "name,x,z,radius,realms\n"
        for _, d := range active.Districts {
            count := 0
            for _, p := range active.Plots { if p.District == d.Name { count++ } }
            s += d.Name+","+n(d.X)+","+n(d.Z)+","+n(d.Radius)+","+n(count)+"\n"
        }
        return s
    case "data/plots":
        s := "path,district,name,txs,x,z,last,callers,activeBlocks,height,settlement\n"
        for _, p := range active.Plots {
            for _, d := range active.Districts {
                if d.Name == p.District {
                    s += p.Path+","+p.District+","+p.Name+","+n(p.Calls)+","+n(d.X+p.X)+","+n(d.Z+p.Z)+","+
                        p.Last+","+n(p.Callers)+","+n(p.Blocks)+","+n(Height(p.Calls))+","+Settlement(p)+"\n"
                    break
                }
            }
        }
        return s
    case "":
        s := "# Realm Ordnance\n\n"+active.Label+" ("+active.Date+") — "+n(len(active.Plots))+" realms across "+n(len(active.Districts))+" islands.\n\n"
        for _, d := range active.Districts {
            s += "## ["+d.Name+"](:"+d.Name+")\n\n"
            count := 0
            for _, p := range active.Plots { if p.District == d.Name { count++ } }
            s += n(count)+" realms.\n\n"
        }
        return s
    }
    name := strings.ToLower(strings.Trim(path, "/"))
    if !districtExists(active.Districts, name) { return "# Unknown island\n\n[Back to chart](:)" }
    s := "# "+name+" island\n\n"+active.Label+" ("+active.Date+")\n\n"
    count := 0
    for _, p := range active.Plots {
        if p.District != name { continue }
        s += "### "+p.Name+" — "+Settlement(p)+"\n\n"+n(p.Calls)+" calls, "+n(p.Callers)+" callers, "+n(p.Blocks)+" active blocks. "+p.Last+"  \n[Enter realm](/"+strings.TrimPrefix(p.Path,"gno.land/")+")\n\n"
        count++
    }
    if count == 0 { s += "Open ground: nothing built here yet.\n\n" }
    return s+"[Back to chart](:)"
}
