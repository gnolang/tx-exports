// Package hubv2 is the multi-admin module router for gnomemepad (Phase 3F).
//
// Diff vs hub v1:
//   - Multiple admins (AddAdmin / RemoveAdmin / ListAdmins)
//   - Any admin may SetModule / TransferAdmin rights via AddAdmin
//   - Ops helpers: AdminCount, IsAdmin
//
// Migrate: deploy hubv2 â†’ re-SetModule all paths â†’ point UI HUB=hubv2
package hubv2

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	// admins: address string -> true
	admins avl.Tree
	inited bool
	// modules: name -> package path string
	modules avl.Tree
)

// Init sets the first admin (deployer EOA). Call once.
func Init(cur realm) {
	if inited {
		panic("hubv2: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("hubv2: EOA only")
	}
	a := cur.Previous().Address()
	admins = avl.Tree{}
	modules = avl.Tree{}
	admins.Set(a.String(), true)
	inited = true
	chain.Emit("Init", "admin", a.String())
}

func requireInit() {
	if !inited {
		panic("hubv2: call Init first")
	}
}

func isAdminAddr(addr address) bool {
	return admins.Has(addr.String())
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("hubv2: EOA only")
	}
	if !isAdminAddr(cur.Previous().Address()) {
		panic("hubv2: not admin")
	}
}

// IsAdmin reports whether addr is an admin.
func IsAdmin(addr string) bool {
	requireInit()
	return admins.Has(strings.TrimSpace(addr))
}

// AdminCount returns number of admins.
func AdminCount() int {
	requireInit()
	return admins.Size()
}

// ListAdmins returns newline-separated admin addresses.
func ListAdmins() string {
	requireInit()
	out := ""
	admins.Iterate("", "", func(key string, _ any) bool {
		if out != "" {
			out += "\n"
		}
		out += key
		return false
	})
	return out
}

// AddAdmin grants admin rights (existing admin only).
func AddAdmin(cur realm, newAdmin address) {
	requireAdmin(cur)
	if !newAdmin.IsValid() {
		panic("hubv2: invalid address")
	}
	if isAdminAddr(newAdmin) {
		panic("hubv2: already admin")
	}
	admins.Set(newAdmin.String(), true)
	chain.Emit("AddAdmin", "addr", newAdmin.String())
}

// RemoveAdmin revokes admin. Cannot remove last admin.
func RemoveAdmin(cur realm, who address) {
	requireAdmin(cur)
	if !who.IsValid() {
		panic("hubv2: invalid address")
	}
	if !isAdminAddr(who) {
		panic("hubv2: not an admin")
	}
	if admins.Size() <= 1 {
		panic("hubv2: cannot remove last admin")
	}
	// Prevent lock-out of caller if they're removing themselves as sole remaining â€” already size>1
	admins.Remove(who.String())
	chain.Emit("RemoveAdmin", "addr", who.String())
}

// SetModule registers or updates a module path (any admin).
func SetModule(cur realm, name, path string) {
	requireAdmin(cur)
	name = strings.TrimSpace(name)
	path = strings.TrimSpace(path)
	if name == "" || len(name) > 32 {
		panic("hubv2: invalid name")
	}
	if path == "" || len(path) > 200 {
		panic("hubv2: invalid path")
	}
	if !strings.HasPrefix(path, "gno.land/") {
		panic("hubv2: path must start with gno.land/")
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			panic("hubv2: name charset")
		}
	}
	modules.Set(name, path)
	chain.Emit("SetModule", "name", name, "path", path)
}

// GetModule returns the package path for name, or "".
func GetModule(name string) string {
	requireInit()
	v := modules.Get(name)
	if v == nil {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return s
}

// ListModules returns newline-separated "name|path".
func ListModules() string {
	requireInit()
	out := ""
	modules.Iterate("", "", func(key string, value any) bool {
		path, _ := value.(string)
		if out != "" {
			out += "\n"
		}
		out += key + "|" + path
		return false
	})
	return out
}

// ModuleCount for ops.
func ModuleCount() int {
	requireInit()
	return modules.Size()
}

// Inited reports Init.
func Inited() bool {
	return inited
}

// Admin returns first admin (compat) â€” first key in tree iteration order.
func Admin() string {
	requireInit()
	out := ""
	admins.Iterate("", "", func(key string, _ any) bool {
		out = key
		return true
	})
	return out
}

func Render(path string) string {
	path = strings.Trim(path, "/")
	if !inited {
		return "# gnomemepad hubv2\n\n> Not initialized.\n"
	}
	out := "# gnomemepad hubv2 (multi-admin)\n\n"
	out += "- Admins: **" + strconv.Itoa(admins.Size()) + "**\n"
	out += "- Modules: **" + strconv.Itoa(modules.Size()) + "**\n\n"
	out += "## Admins\n\n"
	admins.Iterate("", "", func(key string, _ any) bool {
		out += "- `" + key + "`\n"
		return false
	})
	out += "\n## Modules\n\n"
	modules.Iterate("", "", func(key string, value any) bool {
		p, _ := value.(string)
		out += "- **" + key + "**: `" + p + "`\n"
		return false
	})
	out += "\n## API\n\n- SetModule / GetModule / ListModules\n- AddAdmin / RemoveAdmin / ListAdmins / IsAdmin\n"
	_ = path
	return out
}

func resetForTest() {
	admins = avl.Tree{}
	modules = avl.Tree{}
	inited = false
}
