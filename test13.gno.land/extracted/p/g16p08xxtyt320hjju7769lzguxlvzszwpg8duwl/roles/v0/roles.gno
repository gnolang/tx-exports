// Package roles provides simple role-based access control helpers for Gno realms.
// Pure package: no persistent state. Realms store RoleSet data and call these helpers.
//
// Typical roles: "admin", "moderator", "member".
package roles

import "strings"

// RoleSet is a lightweight in-memory representation of address → roles.
// Realms should persist this structure (or an AVL-backed map of RoleSets).
type RoleSet struct {
	// Entries maps address bech32 → comma-separated roles for stable serialization.
	// Example: "admin,member"
	Entries map[string]string
}

// NewRoleSet creates an empty role set.
func NewRoleSet() *RoleSet {
	return &RoleSet{Entries: map[string]string{}}
}

// Has returns true if addr holds the given role.
func (rs *RoleSet) Has(addr, role string) bool {
	if rs == nil || rs.Entries == nil {
		return false
	}
	raw, ok := rs.Entries[addr]
	if !ok || raw == "" {
		return false
	}
	for _, r := range strings.Split(raw, ",") {
		if r == role {
			return true
		}
	}
	return false
}

// Grant adds a role to addr (idempotent).
func (rs *RoleSet) Grant(addr, role string) {
	if rs.Entries == nil {
		rs.Entries = map[string]string{}
	}
	if role == "" || addr == "" {
		return
	}
	if rs.Has(addr, role) {
		return
	}
	raw := rs.Entries[addr]
	if raw == "" {
		rs.Entries[addr] = role
		return
	}
	rs.Entries[addr] = raw + "," + role
}

// Revoke removes a role from addr (idempotent).
func (rs *RoleSet) Revoke(addr, role string) {
	if rs == nil || rs.Entries == nil {
		return
	}
	raw, ok := rs.Entries[addr]
	if !ok || raw == "" {
		return
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, r := range parts {
		if r != role && r != "" {
			out = append(out, r)
		}
	}
	if len(out) == 0 {
		delete(rs.Entries, addr)
		return
	}
	rs.Entries[addr] = strings.Join(out, ",")
}

// IsAdmin is a convenience check for the conventional "admin" role.
func (rs *RoleSet) IsAdmin(addr string) bool {
	return rs.Has(addr, "admin")
}

// Require panics with a clear message if addr lacks role.
// Use at the start of privileged realm functions.
func (rs *RoleSet) Require(addr, role string) {
	if !rs.Has(addr, role) {
		panic("roles: missing role " + role + " for " + addr)
	}
}

// List returns roles for addr as a slice.
func (rs *RoleSet) List(addr string) []string {
	if rs == nil || rs.Entries == nil {
		return nil
	}
	raw, ok := rs.Entries[addr]
	if !ok || raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, r := range parts {
		if r != "" {
			out = append(out, r)
		}
	}
	return out
}
