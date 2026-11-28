package verdict

type Outcome uint8

const (
	OutcomeUnresolved Outcome = iota
	OutcomeYes
	OutcomeNo
	OutcomeInvalid
)

type Resolver interface {
	CanResolve() bool
	Resolve() (Outcome, error)
	Description() string
}
