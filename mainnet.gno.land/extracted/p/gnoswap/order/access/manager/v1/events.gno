package manager

const (
	EventTypeRoleLabel                 = "RoleLabel"
	EventTypeRoleGranted               = "RoleGranted"
	EventTypeRoleRevoked               = "RoleRevoked"
	EventTypeRoleAdminChanged          = "RoleAdminChanged"
	EventTypeRoleGrantDelayChanged     = "RoleGrantDelayChanged"
	EventTypeTargetClosed              = "TargetClosed"
	EventTypeTargetFunctionRoleUpdated = "TargetFunctionRoleUpdated"
)

const (
	AttributeKeyTarget    = "target"
	AttributeKeyRoleID    = "role_id"
	AttributeKeyLabel     = "label"
	AttributeKeyAccount   = "account"
	AttributeKeyDelay     = "delay"
	AttributeKeySince     = "since"
	AttributeKeyNewMember = "new_member"
	AttributeKeyAdmin     = "admin"
	AttributeKeyClosed    = "closed"
	AttributeKeySelector  = "selector"
)
