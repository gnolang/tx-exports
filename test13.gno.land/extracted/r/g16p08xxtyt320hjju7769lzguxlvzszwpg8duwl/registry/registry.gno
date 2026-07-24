// Package registry is the on-chain catalog of GnoForge kits.
// Anyone can register a kit pointer (path + metadata); admins can feature/unfeature.
package registry

import (
	"strconv"
	"strings"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

// Kit metadata entry.
type Kit struct {
	ID          string
	Name        string
	Version     string
	PkgPath     string
	Category    string
	Description string
	Tags        string // comma-separated
	Author      string
	License     string
	Featured    bool
}

var (
	roleSet *roles.RoleSet
	kits    map[string]Kit
	order   []string
	inited  bool
)

func ensure() {
	if roleSet == nil {
		roleSet = roles.NewRoleSet()
	}
	if kits == nil {
		kits = map[string]Kit{}
	}
}

// InitRegistry sets the first admin.
func InitRegistry(cur realm) string {
	ensure()
	if inited {
		panic("registry: already initialized")
	}
	caller := cur.Previous().Address().String()
	roleSet.Grant(caller, "admin")
	inited = true
	return "ok"
}

// RegisterKit adds or updates a kit listing (author or admin).
func RegisterKit(
	cur realm,
	id, name, version, pkgpath, category, description, tags, license string,
) string {
	ensure()
	if !inited {
		panic("registry: not initialized")
	}
	caller := cur.Previous().Address().String()
	id = strings.TrimSpace(id)
	if id == "" || name == "" || pkgpath == "" {
		panic("registry: id, name, pkgpath required")
	}
	if existing, ok := kits[id]; ok {
		if existing.Author != caller && !roleSet.IsAdmin(caller) {
			panic("registry: only author or admin can update")
		}
		existing.Name = name
		existing.Version = version
		existing.PkgPath = pkgpath
		existing.Category = category
		existing.Description = description
		existing.Tags = tags
		existing.License = license
		kits[id] = existing
		return "updated:" + id
	}
	k := Kit{
		ID:          id,
		Name:        name,
		Version:     version,
		PkgPath:     pkgpath,
		Category:    category,
		Description: description,
		Tags:        tags,
		Author:      caller,
		License:     license,
		Featured:    false,
	}
	kits[id] = k
	order = append(order, id)
	return "registered:" + id
}

// SetFeatured toggles featured flag (admin).
func SetFeatured(cur realm, id string, featured bool) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	k, ok := kits[id]
	if !ok {
		panic("registry: unknown kit")
	}
	k.Featured = featured
	kits[id] = k
	return "ok"
}

// GetKit returns a short summary string (for clients).
func GetKit(cur realm, id string) string {
	ensure()
	k, ok := kits[id]
	if !ok {
		return ""
	}
	feat := "0"
	if k.Featured {
		feat = "1"
	}
	return strings.Join([]string{
		k.ID, k.Name, k.Version, k.PkgPath, k.Category, k.Author, k.License, feat,
	}, "|")
}

// Render catalog for gnoweb.
func Render(path string) string {
	ensure()
	var b strings.Builder
	b.WriteString("# GnoForge Registry\n\n")
	b.WriteString("On-chain catalog of realm starter kits and packages.\n\n")
	if !inited {
		b.WriteString("_Registry not initialized._\n")
		return b.String()
	}
	if path != "" {
		if k, ok := kits[path]; ok {
			b.WriteString("## " + k.Name + "\n\n")
			b.WriteString("- ID: `" + k.ID + "`\n")
			b.WriteString("- Version: `" + k.Version + "`\n")
			b.WriteString("- Path: `" + k.PkgPath + "`\n")
			b.WriteString("- Category: `" + k.Category + "`\n")
			b.WriteString("- Author: `" + k.Author + "`\n")
			b.WriteString("- License: `" + k.License + "`\n")
			b.WriteString("- Tags: " + k.Tags + "\n\n")
			b.WriteString(k.Description + "\n")
			return b.String()
		}
	}
	b.WriteString("**Kits listed:** " + strconv.Itoa(len(order)) + "\n\n")
	for _, id := range order {
		k := kits[id]
		star := ""
		if k.Featured {
			star = " â˜…"
		}
		b.WriteString("### " + k.Name + star + "\n\n")
		b.WriteString("`" + k.ID + "` Â· v" + k.Version + " Â· " + k.Category + "\n\n")
		b.WriteString(k.Description + "\n\n")
		b.WriteString("Path: `" + k.PkgPath + "`\n\n")
	}
	if len(order) == 0 {
		b.WriteString("_No kits registered yet. Call `RegisterKit`._\n")
	}
	b.WriteString("---\n*GnoForge - packages marketplace for Gno.land*\n")
	return b.String()
}
