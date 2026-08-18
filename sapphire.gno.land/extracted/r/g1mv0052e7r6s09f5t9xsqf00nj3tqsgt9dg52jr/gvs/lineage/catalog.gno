package lineage

import (
	"chain"
	"chain/runtime/unsafe"

	lin "gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/lineage"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Catalog of vault versions. It never holds user funds and never calls
// into a vault. Upgrades add a row; old vaults stay frozen on their path.

var (
	admin   address
	current string
	byID    avl.Tree
)

func init() {
	admin = unsafe.OriginCaller()
}

func Admin() address  { return admin }
func CurrentID() string { return current }

func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	admin = next
}

// Register adds a version. Does not pause or migrate any vault.
func Register(cur realm, id, name, pkgPath, predecessor, status string) {
	mustAdmin(cur)
	if byID.Has(id) {
		panic("id taken")
	}
	v := lin.Version{
		ID:          id,
		Name:        name,
		PkgPath:     pkgPath,
		Predecessor: predecessor,
		Status:      status,
	}
	lin.Validate(v)
	if predecessor != "" {
		pv := byID.Get(predecessor)
		if pv == nil {
			panic("unknown predecessor")
		}
		prev := pv.(lin.Version)
		if prev.Successor != "" && prev.Successor != id {
			panic("predecessor already has a successor")
		}
		prev.Successor = id
		if prev.Status == lin.StatusLive {
			prev.Status = lin.StatusLegacy
		}
		byID.Set(predecessor, prev)
	}
	byID.Set(id, v)
	if current == "" || status == lin.StatusLive {
		// only one live: demote previous current
		if current != "" && current != id {
			cv := byID.Get(current)
			if cv != nil {
				curV := cv.(lin.Version)
				if curV.Status == lin.StatusLive {
					curV.Status = lin.StatusLegacy
					byID.Set(current, curV)
				}
			}
		}
		if status == lin.StatusLive {
			current = id
		}
	}
	chain.Emit("VersionRegister", "id", id, "pkg", pkgPath, "status", status)
}

// SetCurrent points new deposits at id. Does not move funds.
func SetCurrent(cur realm, id string) {
	mustAdmin(cur)
	v := mustGet(id)
	if current != "" && current != id {
		old := mustGet(current)
		if old.Status == lin.StatusLive {
			old.Status = lin.StatusLegacy
			byID.Set(current, old)
		}
	}
	v.Status = lin.StatusLive
	byID.Set(id, v)
	current = id
	chain.Emit("VersionCurrent", "id", id)
}

// Sunset marks a version closed to new deposits. Existing positions stay.
func Sunset(cur realm, id string) {
	mustAdmin(cur)
	v := mustGet(id)
	if current == id {
		panic("cannot sunset the current version")
	}
	v.Status = lin.StatusSunset
	byID.Set(id, v)
	chain.Emit("VersionSunset", "id", id)
}

func Get(id string) lin.Version {
	v := byID.Get(id)
	if v == nil {
		return lin.Version{}
	}
	return v.(lin.Version)
}

func Current() lin.Version {
	if current == "" {
		return lin.Version{}
	}
	return Get(current)
}

func Count() int { return byID.Size() }

func IDs() []string {
	out := make([]string, 0, byID.Size())
	byID.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

func mustGet(id string) lin.Version {
	v := byID.Get(id)
	if v == nil {
		panic("unknown version")
	}
	return v.(lin.Version)
}

func mustAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — Version lineage\n\n"
	out += "Old vaults stay frozen with their funds. New deposits go to **current**.\n\n"
	if current != "" {
		out += "- **Current**: `" + sanitize.InlineText(current) + "`\n\n"
	}
	if byID.Size() == 0 {
		out += "> [!NOTE]\n> No versions registered.\n"
		return out
	}
	out += "| ID | Status | Package | Successor |\n|---|---|---|---|\n"
	byID.Iterate("", "", func(key string, value any) bool {
		v := value.(lin.Version)
		out += "| " + sanitize.TableCell(v.ID) +
			" | " + sanitize.TableCell(v.Status) +
			" | `" + sanitize.InlineText(v.PkgPath) + "`" +
			" | " + sanitize.TableCell(v.Successor) + " |\n"
		return false
	})
	return out
}
