package manager

type Selector string

func NewSelector(selector string) Selector {
	return Selector(selector)
}

type CanCallResult struct {
	Immediate bool
}

func NewCanCallResult(immediate bool) CanCallResult {
	return CanCallResult{
		Immediate: immediate,
	}
}

type HasRoleResult struct {
	IsMember bool
}

func NewHasRoleResult(isMember bool) HasRoleResult {
	return HasRoleResult{
		IsMember: isMember,
	}
}
