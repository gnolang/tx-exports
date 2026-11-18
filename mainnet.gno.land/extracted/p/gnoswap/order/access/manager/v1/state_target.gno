package manager

type TargetConfig struct {
	FunctionRoles map[Selector]RoleId
	Closed        bool
}

func NewTargetConfig(closed bool) *TargetConfig {
	return &TargetConfig{
		FunctionRoles: make(map[Selector]RoleId),
		Closed:        closed,
	}
}

func (targetConfig *TargetConfig) setFunctionRole(selector Selector, role RoleId) {
	targetConfig.ensureFunctionRoles()

	targetConfig.FunctionRoles[selector] = role
}

func (targetConfig *TargetConfig) setFunctionRoles(selectors []Selector, role RoleId) {
	for i := range selectors {
		targetConfig.setFunctionRole(selectors[i], role)
	}
}

func (targetConfig *TargetConfig) functionRole(selector Selector) RoleId {
	targetConfig.ensureFunctionRoles()

	role, found := targetConfig.FunctionRoles[selector]
	if !found {
		return AdminRole
	}

	return role
}

func (targetConfig *TargetConfig) setClosed(closed bool) {
	targetConfig.Closed = closed
}

func (targetConfig *TargetConfig) isClosed() bool {
	return targetConfig.Closed
}

func (targetConfig *TargetConfig) ensureFunctionRoles() {
	if targetConfig.FunctionRoles == nil {
		targetConfig.FunctionRoles = make(map[Selector]RoleId)
	}
}
