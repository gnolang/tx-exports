package manager

import "strconv"

type Selector string

func NewSelector(selector string) Selector {
	return Selector(selector)
}

type Delay uint32

func NewDelay(delay uint32) Delay {
	return Delay(delay)
}

func (d Delay) Uint32() uint32 {
	return uint32(d)
}

func (d Delay) String() string {
	return strconv.FormatUint(uint64(d), 10)
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
