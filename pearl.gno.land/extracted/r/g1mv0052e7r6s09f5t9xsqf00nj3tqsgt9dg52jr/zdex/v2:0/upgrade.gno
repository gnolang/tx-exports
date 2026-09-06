package zdex

import (
	"chain"

	"gno.land/p/nt/ufmt/v0"
)

// protoVersion is this realm generation. Gno packages are immutable:
// v2 is this path. A later /v3 ships as a new package; LP here stays.
// Admin points NextPkg / SetModule at the successor.
const protoVersion = "2"

const (
	modSwap   = "swap"
	modLP     = "lp"
	modCreate = "create"
	modBook   = "book"
	modPoints = "points"
	modQuote  = "quote"
	modAdmin  = "admin"
)

const defaultCaps = "swap;lp;create;book;points;quote;feeShare;noStakeLp"

var nextPkg string

func validModule(name string) bool {
	return name == modSwap || name == modLP || name == modCreate ||
		name == modBook || name == modPoints || name == modQuote || name == modAdmin
}

func moduleNames() []string {
	return []string{modSwap, modLP, modCreate, modBook, modPoints, modQuote, modAdmin}
}

// Version is the ABI generation of this hub. v1 freeze: SwapExactIn,
// AddLiquidity, CreatePool, book, and points keep their names.
func Version() string {
	return protoVersion
}

// Caps is a semicolon-separated capability list so UIs feature-gate
// without coupling to a package path. Missing Caps on an older realm
// means the client should fall back to probing individual queries.
func Caps() string {
	return defaultCaps
}

// ThisPkg is the path of this hub realm.
func ThisPkg() string {
	return thisPkg()
}

// NextPkg is empty until admin points this generation at a successor.
// Liquidity and open orders stay in this package; the UI may switch
// new flow to NextPkg without rewriting swap/LP/points clients.
func NextPkg() string {
	return nextPkg
}

func SetNextPkg(cur realm, path string) {
	mustOwner(cur)
	nextPkg = path
	chain.Emit("NextPkg", "path", path)
}

// ModuleOf returns the package that currently owns a surface.
// Unmapped names resolve to this hub so a v2 book can move alone.
func ModuleOf(name string) string {
	if !validModule(name) {
		return thisPkg()
	}
	v := modules.Get(name)
	if v == nil {
		return thisPkg()
	}
	s, ok := v.(string)
	if !ok || s == "" {
		return thisPkg()
	}
	return s
}

func SetModule(cur realm, name, pkg string) {
	mustOwner(cur)
	require(validModule(name), "zdex: unknown module")
	if pkg == "" {
		modules.Remove(name)
	} else {
		modules.Set(name, pkg)
	}
	chain.Emit("SetModule", "name", name, "pkg", pkg)
}

// Modules is one surface per line: name;pkg
func Modules() string {
	out := ""
	for _, n := range moduleNames() {
		line := n + ";" + ModuleOf(n)
		if out != "" {
			out += "\n"
		}
		out += line
	}
	return out
}

// HubSnapshot is a single-line UI record:
// version;thisPkg;nextPkg;caps  (caps may contain further semicolons)
func HubSnapshot() string {
	return ufmt.Sprintf("%s;%s;%s;%s", Version(), thisPkg(), nextPkg, Caps())
}
