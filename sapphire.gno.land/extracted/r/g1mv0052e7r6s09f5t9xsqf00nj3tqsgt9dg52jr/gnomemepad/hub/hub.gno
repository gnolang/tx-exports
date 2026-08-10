// Package hub is the version/module router for gnomemepad.
//
// UI and tooling should resolve the active pad (and other modules) via hub
// instead of hardcoding padvN paths. Admins rotate module paths without
// redeploying every consumer.
//
//	Init â†’ SetModule("pad", "gno.land/r/.../padv4") â†’ GetModule("pad")
package hub

import (
	"chain"
	"strings"

	"gno.land/p/nt/avl/v0"
)

var (
	admin  address
	inited bool
	// modules: name -> package path string
	modules avl.Tree
)

// Init sets the hub admin (first EOA). Call once after deploy.
func Init(cur realm) {
	if inited {
		panic("hub: already initialized")
	}
	if !cur.Previous().IsUserCall() {
		panic("hub: EOA only")
	}
	admin = cur.Previous().Address()
	inited = true
	modules = avl.Tree{}
	chain.Emit("Init", "admin", admin.String())
}

func requireInit() {
	if !inited {
		panic("hub: call Init first")
	}
}

func requireAdmin(cur realm) {
	requireInit()
	if !cur.Previous().IsUserCall() {
		panic("hub: EOA only")
	}
	if cur.Previous().Address() != admin {
		panic("hub: not admin")
	}
}

// SetModule registers or updates a module path (admin only).
// name: short key e.g. "pad", "profile", "legacy_pad"
// path: full gno package path
func SetModule(cur realm, name, path string) {
	requireAdmin(cur)
	name = strings.TrimSpace(name)
	path = strings.TrimSpace(path)
	if name == "" || len(name) > 32 {
		panic("hub: invalid name")
	}
	if path == "" || len(path) > 200 {
		panic("hub: invalid path")
	}
	if !strings.HasPrefix(path, "gno.land/") {
		panic("hub: path must start with gno.land/")
	}
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			panic("hub: name charset")
		}
	}
	modules.Set(name, path)
	chain.Emit("SetModule", "name", name, "path", path)
}

// GetModule returns the package path for name, or "" if unset.
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

// ListModules returns newline-separated "name|path" lines (sorted by name).
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

// TransferAdmin rotates hub admin.
func TransferAdmin(cur realm, newAdmin address) {
	requireAdmin(cur)
	if !newAdmin.IsValid() {
		panic("hub: invalid address")
	}
	if newAdmin == admin {
		panic("hub: same admin")
	}
	old := admin
	admin = newAdmin
	chain.Emit("TransferAdmin", "from", old.String(), "to", newAdmin.String())
}

// Admin returns the hub admin address.
func Admin() string {
	requireInit()
	return admin.String()
}

// Inited reports whether Init was called.
func Inited() bool {
	return inited
}

// Render â€” discovery home.
func Render(path string) string {
	path = strings.Trim(path, "/")
	if !inited {
		return "# gnomemepad hub\n\n> Not initialized. Call Init.\n"
	}
	out := "# gnomemepad hub\n\n"
	out += "- Admin: `" + admin.String() + "`\n\n"
	out += "## Modules\n\n"
	n := 0
	modules.Iterate("", "", func(key string, value any) bool {
		path, _ := value.(string)
		out += "- **" + key + "**: `" + path + "`\n"
		n++
		return false
	})
	if n == 0 {
		out += "_No modules registered. Admin: SetModule(name, path)._\n"
	}
	out += "\n## API\n\n"
	out += "- `GetModule(name)` / `ListModules()`\n"
	out += "- `SetModule(name, path)` â€” admin\n"
	out += "- `TransferAdmin(newAdmin)` â€” admin\n"
	_ = path
	return out
}

// resetForTest â€” unit tests only (unexported).
func resetForTest() {
	var zero address
	admin = zero
	inited = false
	modules = avl.Tree{}
}
