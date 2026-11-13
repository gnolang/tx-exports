package keeper

import (
	"sort"

	"gno.land/p/gnoswap/order/access/manager/v0"
	"gno.land/p/onbloc/json/v0"
)

// IsAuthorized reports whether caller may call selector on target now.
func IsAuthorized(target string, selector manager.Selector, caller address) bool {
	return accessState.IsAuthorized(caller, target, selector)
}

// HasRole reports whether account is an active member of role.
func HasRole(role manager.RoleId, account address) bool {
	return accessState.HasRole(role, account).IsMember
}

// GetRoleMemberSince returns when account's membership of role becomes
// active, or 0 if account is not a member.
func GetRoleMemberSince(role manager.RoleId, account address) int64 {
	return accessState.GetRoleMemberSince(role, account).Int64()
}

// GetRoleGrantDelay returns the grant delay of role in effect now, in seconds.
func GetRoleGrantDelay(role manager.RoleId) uint32 {
	return accessState.GetRoleGrantDelay(role)
}

// GetRoleLabel returns the label of a registered role, or "".
func GetRoleLabel(role manager.RoleId) string {
	return roleLabels[role]
}

// GetRolesJSON returns the registered roles as a JSON array of
// {"id", "label"} objects, ordered by id.
func GetRolesJSON() string {
	ids := make([]int, 0, len(roleLabels))
	for role := range roleLabels {
		ids = append(ids, int(role))
	}

	sort.Ints(ids)

	nodes := make([]*json.Node, 0, len(ids))
	for _, id := range ids {
		role := manager.RoleId(id)
		nodes = append(nodes, json.ObjectNode("", map[string]*json.Node{
			"id":    json.StringNode("", role.String()),
			"label": json.StringNode("", roleLabels[role]),
		}))
	}

	encoded, err := json.Marshal(json.ArrayNode("", nodes))
	if err != nil {
		panic(err.Error())
	}

	return string(encoded)
}

// GetTargetFunctionRole returns the role assigned to selector on target.
// Unassigned selectors return manager.AdminRole, which no account holds.
func GetTargetFunctionRole(target string, selector manager.Selector) manager.RoleId {
	return accessState.GetTargetFunctionRole(target, selector)
}

// IsTargetClosed reports whether target rejects every call.
func IsTargetClosed(target string) bool {
	return accessState.IsTargetClosed(target)
}
