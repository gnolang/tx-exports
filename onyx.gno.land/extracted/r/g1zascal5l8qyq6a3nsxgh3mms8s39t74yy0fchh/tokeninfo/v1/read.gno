package tokeninfo

import "gno.land/p/nt/avl/v0"

// Get returns a copy of the profile of token. ok is false when there is none
// or a moderator has hidden it.
func Get(token string) (p Profile, ok bool) {
	v := profiles.Get(token)
	if v == nil || hidden.Has(token) {
		return Profile{}, false
	}
	return *(v.(*Profile)), true
}

// Fields is Get for clients that read with vm/qeval, which prints one value
// per line. Everything is empty when there is no visible profile.
func Fields(token string) (description, website, logo, x, telegram, discord, github, updatedBy string, updatedAt int64, role string) {
	p, ok := Get(token)
	if !ok {
		return
	}
	return p.Description, p.Website, p.Logo, p.X, p.Telegram, p.Discord, p.GitHub, p.UpdatedBy.String(), p.UpdatedAt, p.Role
}

// HiddenReason returns why a moderator hid token, or "".
func HiddenReason(token string) string {
	if v := hidden.Get(token); v != nil {
		return v.(string)
	}
	return ""
}

// Editors returns the editors of token, in address order.
func Editors(token string) []address {
	var out []address
	if set := editors.Get(token); set != nil {
		set.(*avl.Tree).Iterate("", "", func(k string, _ any) bool {
			out = append(out, address(k))
			return false
		})
	}
	return out
}

// Count returns how many tokens have a profile, hidden ones included.
func Count() int { return profiles.Size() }

// List returns up to limit token paths with a profile, in path order,
// starting at offset. Hidden ones are included; check with Get.
func List(offset, limit int) []string {
	if limit > 100 {
		limit = 100
	}
	var out []string
	profiles.IterateByOffset(offset, limit, func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}
