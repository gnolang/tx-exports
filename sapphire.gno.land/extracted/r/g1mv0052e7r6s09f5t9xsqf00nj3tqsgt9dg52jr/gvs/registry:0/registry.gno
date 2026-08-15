package registry

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/protocol"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

var (
	admin   address
	byID    avl.Tree
	byPath  avl.Tree
)

func init() {
	admin = unsafe.OriginCaller()
}

// Admin is the address that may deregister or rotate ownership.
func Admin() address { return admin }

// TransferAdmin rotates registry ownership.
func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	prev := admin
	admin = next
	chain.Emit("OwnershipChange", "old", prev.String(), "new", next.String())
}

// Register lists a strategy. The caller must be the strategy realm itself so
// an EOA cannot claim an arbitrary pkg path (Class 2).
func Register(cur realm, id, name, proto, want string) {
	caller := cur.Previous()
	pkg := caller.PkgPath()
	if pkg == "" {
		panic("only a strategy realm can register itself")
	}
	if id == "" || name == "" || proto == "" || want == "" {
		panic("incomplete meta")
	}
	if byID.Has(id) {
		panic("id taken")
	}
	if byPath.Has(pkg) {
		panic("pkg already registered")
	}
	meta := protocol.Meta{
		ID:       id,
		Name:     name,
		Protocol: proto,
		PkgPath:  pkg,
		Want:     want,
	}
	byID.Set(id, meta)
	byPath.Set(pkg, id)
	chain.Emit("StrategyRegister", "id", id, "pkg", pkg, "protocol", proto)
}

// Deregister removes a listing. Admin or the listed realm may call it.
func Deregister(cur realm, id string) {
	v := byID.Get(id)
	if v == nil {
		panic("unknown id")
	}
	meta := v.(protocol.Meta)
	prev := cur.Previous()
	if prev.Address() != admin && prev.PkgPath() != meta.PkgPath {
		panic("not authorized")
	}
	byID.Remove(id)
	byPath.Remove(meta.PkgPath)
	chain.Emit("StrategyDeregister", "id", id)
}

// Get returns listing metadata. Empty ID if missing.
func Get(id string) protocol.Meta {
	v := byID.Get(id)
	if v == nil {
		return protocol.Meta{}
	}
	return v.(protocol.Meta)
}

// Count is the number of listed strategies.
func Count() int { return byID.Size() }

// IDs returns registered strategy ids in tree order.
func IDs() []string {
	out := make([]string, 0, byID.Size())
	byID.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

func mustAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

// Render lists strategies for gnoweb.
func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — Registry\n\n"
	out += "Listed adapters. Each id is a live strategy realm.\n\n"
	if byID.Size() == 0 {
		out += "> [!NOTE]\n> No strategies registered yet.\n"
		return out
	}
	out += "| ID | Protocol | Want | Package |\n|---|---|---|---|\n"
	byID.Iterate("", "", func(key string, value any) bool {
		m := value.(protocol.Meta)
		out += "| " + sanitize.TableCell(m.ID) +
			" | " + sanitize.TableCell(m.Protocol) +
			" | " + sanitize.TableCell(m.Want) +
			" | `" + sanitize.InlineText(m.PkgPath) + "` |\n"
		return false
	})
	return out
}
