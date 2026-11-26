// Package registry is the authoritative on-chain registry of PROOFLOOM
// projects and software components. It is the ownership backbone of the
// protocol: every other realm consults it for authorization decisions.
//
// Security model:
//   - The protocol admin (set once at Init) can only manage registrar
//     allow-lists, never project state owned by users.
//   - Project owners are recorded from cur.Previous().Address() and never
//     from caller-supplied arguments.
//   - Getters return value copies; internal maps and slices are never
//     exposed.
package registry

import (
        "gno.land/r/g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq/proofloom/core"

        "sort"
        "strings"
        "time"
)

// Project is a registered software project. Owned by the address that
// registered it.
type Project struct {
        ID          string
        Name        string
        Description string
        Repo        string
        Category    string
        Visibility  string // "public" or "private"
        Owner       address
        CreatedAt   int64
        Archived    bool
}

// Component is a software component (package, image, binary, SBOM...)
// associated with a project.
type Component struct {
        ID           string
        ProjectID    string
        Name         string
        License      string
        ArtifactType string // source, container, binary, sbom, docs
        Owner        address
        CreatedAt    int64
        Deprecated   bool
}

var (
        projects   map[string]*Project
        components map[string]*Component

        admin      address
        registrars map[string]bool // addresses allowed to register projects
)

// projectIDs preserves registration order for deterministic listing.
var projectIDs []string
var componentIDs []string

func mustAdmin(cur realm) {
        if cur.Previous().Address() != admin {
                panic("registry: caller is not protocol admin")
        }
        if !cur.IsCurrent() {
                panic("registry: cross-realm admin call rejected")
        }
}

// IsInitialized reports whether the realm has been initialized.
func IsInitialized() bool {
        return admin != ""
}

// assertCore panics when the realm is used before Init.
func assertCore() {
        if admin == "" {
                panic("registry: realm not initialized")
        }
}

// Init initializes the realm. The caller of the deployment transaction
// becomes the protocol admin. Idempotent: a second call always panics.
func Init(cur realm) {
        if admin != "" {
                panic("registry: already initialized")
        }
        projects = make(map[string]*Project)
        components = make(map[string]*Component)
        registrars = make(map[string]bool)
        admin = cur.Previous().Address()
}

// SetAdmin transfers protocol admin to a new address. Only the current admin
// may call it.
func SetAdmin(cur realm, next address) {
        mustAdmin(cur)
        if !core.IsValidAddress(string(next)) {
                panic("registry: invalid admin address")
        }
        admin = next
}

// GrantRegistrar allow-lists an address to register projects. Only the
// protocol admin may grant registration rights.
func GrantRegistrar(cur realm, addr address) {
        mustAdmin(cur)
        if !core.IsValidAddress(string(addr)) {
                panic("registry: invalid registrar address")
        }
        registrars[string(addr)] = true
}

// RevokeRegistrar removes an address from the registrar allow-list.
func RevokeRegistrar(cur realm, addr address) {
        mustAdmin(cur)
        delete(registrars, string(addr))
}

// IsRegistrar reports whether addr may register projects (owner implicitly
// administers).
func IsRegistrar(addr address) bool {
        assertCore()
        if string(addr) == string(admin) {
                return true
        }
        return registrars[string(addr)]
}

// RegisterProject records a new project owned by the caller.
func RegisterProject(cur realm, id, name, description, repo, category, visibility string) {
        assertCore()
        caller := cur.Previous().Address()
        if !cur.IsCurrent() {
                panic("registry: project registration must run in current realm")
        }
        if !core.IsValidID(id) {
                panic("registry: invalid project id")
        }
        if _, ok := projects[id]; ok {
                panic("registry: project id already registered")
        }
        if !core.BoundedText(name, 128) || !core.BoundedText(description, core.MaxTextLen) ||
                !core.BoundedText(repo, 256) || !core.BoundedText(category, 64) {
                panic("registry: metadata exceeds size limits")
        }
        if name == "" {
                panic("registry: project name required")
        }
        if visibility != "public" && visibility != "private" {
                panic("registry: visibility must be public or private")
        }
        if !IsRegistrar(caller) {
                panic("registry: caller is not a registrar")
        }
        projects[id] = &Project{
                ID:          id,
                Name:        name,
                Description: description,
                Repo:        repo,
                Category:    category,
                Visibility:  visibility,
                Owner:       caller,
                CreatedAt:   time.Now().Unix(),
                Archived:    false,
        }
        projectIDs = append(projectIDs, id)
}

// TransferProject moves project ownership to a new address. Only the current
// owner may transfer.
func TransferProject(cur realm, id string, next address) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                panic("registry: unknown project")
        }
        caller := cur.Previous().Address()
        if caller != p.Owner {
                panic("registry: only the project owner may transfer ownership")
        }
        if !core.IsValidAddress(string(next)) {
                panic("registry: invalid target owner")
        }
        if string(next) == string(p.Owner) {
                panic("registry: target owner already owns project")
        }
        p.Owner = next
}

// SetProjectVisibility toggles public/private. Owner only.
func SetProjectVisibility(cur realm, id, visibility string) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                panic("registry: unknown project")
        }
        if cur.Previous().Address() != p.Owner {
                panic("registry: only the project owner may change visibility")
        }
        if visibility != "public" && visibility != "private" {
                panic("registry: visibility must be public or private")
        }
        p.Visibility = visibility
}

// ArchiveProject soft-archives a project. Owner or protocol admin.
func ArchiveProject(cur realm, id string) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                panic("registry: unknown project")
        }
        caller := cur.Previous().Address()
        if caller != p.Owner && caller != admin {
                panic("registry: not authorized to archive project")
        }
        p.Archived = true
}

// RestoreProject reactivates an archived project. Owner only.
func RestoreProject(cur realm, id string) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                panic("registry: unknown project")
        }
        if cur.Previous().Address() != p.Owner {
                panic("registry: only the project owner may restore")
        }
        p.Archived = false
}

// RegisterComponent records a component under a project owned by the caller.
func RegisterComponent(cur realm, id, projectID, name, license, artifactType string) {
        assertCore()
        p, ok := projects[projectID]
        if !ok {
                panic("registry: unknown project")
        }
        if p.Archived {
                panic("registry: project is archived")
        }
        caller := cur.Previous().Address()
        if caller != p.Owner {
                panic("registry: only the project owner may register components")
        }
        if !core.IsValidID(id) {
                panic("registry: invalid component id")
        }
        if _, exists := components[id]; exists {
                panic("registry: component id already registered")
        }
        if !core.BoundedText(name, 128) || !core.BoundedText(license, 64) || !core.BoundedText(artifactType, 32) {
                panic("registry: component metadata exceeds size limits")
        }
        validTypes := map[string]bool{"source": true, "container": true, "binary": true, "sbom": true, "docs": true, "library": true}
        if !validTypes[artifactType] {
                panic("registry: unsupported artifact type")
        }
        components[id] = &Component{
                ID:           id,
                ProjectID:    projectID,
                Name:         name,
                License:      license,
                ArtifactType: artifactType,
                Owner:        caller,
                CreatedAt:    time.Now().Unix(),
                Deprecated:   false,
        }
        componentIDs = append(componentIDs, id)
}

// DeprecateComponent marks a component deprecated. Owner only.
func DeprecateComponent(cur realm, id string) {
        assertCore()
        c, ok := components[id]
        if !ok {
                panic("registry: unknown component")
        }
        if cur.Previous().Address() != c.Owner {
                panic("registry: only the component owner may deprecate")
        }
        c.Deprecated = true
}

// HasProject reports existence regardless of visibility.
func HasProject(id string) bool {
        assertCore()
        _, ok := projects[id]
        return ok
}

// GetProject returns a copy of the project if it exists and is public, or
// the caller is the owner. Private projects are hidden from foreign readers.
func GetProject(id string) (Project, bool) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                return Project{}, false
        }
        return *p, true
}

// GetProjectFor checks visibility for a specific reader address.
func GetProjectFor(id string, reader address) (Project, bool) {
        assertCore()
        p, ok := projects[id]
        if !ok {
                return Project{}, false
        }
        if p.Visibility == "private" && reader != p.Owner {
                return Project{}, false
        }
        return *p, true
}

// GetPublicProject returns the project only when public. Used by the verify
// realm and external consumers.
func GetPublicProject(id string) (Project, bool) {
        assertCore()
        p, ok := projects[id]
        if !ok || p.Visibility != "public" || p.Archived {
                return Project{}, false
        }
        return *p, true
}

// IsProjectOwner reports whether addr owns the given project.
func IsProjectOwner(id string, addr address) bool {
        assertCore()
        p, ok := projects[id]
        if !ok {
                return false
        }
        return p.Owner == addr
}

// GetComponent returns a copy of the component.
func GetComponent(id string) (Component, bool) {
        assertCore()
        c, ok := components[id]
        if !ok {
                return Component{}, false
        }
        return *c, true
}

// IsComponentOwner reports whether addr owns the component's project.
func IsComponentOwner(id string, addr address) bool {
        assertCore()
        c, ok := components[id]
        if !ok {
                return false
        }
        return c.Owner == addr
}

// ListProjectIDs returns all project IDs, newest first.
func ListProjectIDs() []string {
        assertCore()
        out := make([]string, len(projectIDs))
        copy(out, projectIDs)
        // newest first: reverse of registration order
        for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
                out[i], out[j] = out[j], out[i]
        }
        return out
}

// ListPublicProjectIDs returns IDs of public, non-archived projects, sorted
// for deterministic output.
func ListPublicProjectIDs() []string {
        assertCore()
        var out []string
        for _, id := range projectIDs {
                p := projects[id]
                if p != nil && p.Visibility == "public" && !p.Archived {
                        out = append(out, id)
                }
        }
        sort.Strings(out)
        return out
}

// ListComponentIDsByProject returns component IDs for a project, newest first.
func ListComponentIDsByProject(projectID string) []string {
        assertCore()
        var out []string
        for _, id := range componentIDs {
                if c := components[id]; c != nil && c.ProjectID == projectID {
                        out = append(out, id)
                }
        }
        for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
                out[i], out[j] = out[j], out[i]
        }
        return out
}

// ProjectCount returns the number of registered projects.
func ProjectCount() int {
        assertCore()
        return len(projectIDs)
}

// ComponentCount returns the number of registered components.
func ComponentCount() int {
        assertCore()
        return len(componentIDs)
}

// IsProtocolAdmin reports whether addr is the protocol admin. Other realms
// delegate admin decisions to the same root of trust.
func IsProtocolAdmin(addr address) bool {
        assertCore()
        return string(addr) == string(admin)
}

// ProtocolAdminAddress returns the current admin address.
func ProtocolAdminAddress() address {
        assertCore()
        return admin
}

// NormalizeRepo trims scheme and trailing slash for consistent repo keys.
func NormalizeRepo(repo string) string {
        r := strings.TrimSuffix(repo, "/")
        r = strings.TrimPrefix(r, "https://")
        r = strings.TrimPrefix(r, "http://")
        r = strings.TrimPrefix(r, "git@")
        return r
}
