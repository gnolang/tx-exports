package halt

// Operations that can be halted.
const (
	OperationExecute  = "execute"
	OperationWithdraw = "withdraw"
)

// TargetAll addresses every target at once.
const TargetAll = "all"

// Targets registered at deployment; more are added with AddTarget.
const (
	TargetDCA   = "dca"
	TargetLimit = "limit"
)

// maxTargetLength bounds a target name.
const maxTargetLength = 32

var operations = []string{OperationExecute, OperationWithdraw}
