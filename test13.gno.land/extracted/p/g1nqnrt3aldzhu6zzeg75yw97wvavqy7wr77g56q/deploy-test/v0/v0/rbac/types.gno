package rbac

type Permission struct {
	Name        string
	Description string
}

type AssignmentContext struct {
	EntityID               string
	User                   address
	RoleName               string
	CurrentRoleAssignments int
	UserRoleCount          int
}

// AssignmentCheck is trusted policy code supplied by the RBAC owner.
// It is stored internally and is never returned through Role views.
type AssignmentCheck func(AssignmentContext) bool

// RoleSpec is the input type for creating or updating roles.
// AssignmentCheck may close over owner state, so role mutation must be
// restricted by the owning realm that stores RBAC.
type RoleSpec struct {
	Name            string
	Description     string
	PermissionNames []string
	Metadata        map[string]string
	AssignmentCheck AssignmentCheck
}

// Role is a public read model. It intentionally excludes AssignmentCheck
// so stored callback capabilities are not exposed to callers.
type Role struct {
	Name            string
	Description     string
	PermissionNames []string
	Metadata        map[string]string
}
