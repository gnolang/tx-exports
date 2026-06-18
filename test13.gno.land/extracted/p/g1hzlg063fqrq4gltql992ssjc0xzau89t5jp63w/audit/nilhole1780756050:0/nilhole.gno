package nilhole

type Slot struct{ Field string }

type Mutator interface{ Run(s *Slot) }

type Dispatcher struct{}

func (d *Dispatcher) UseMutator(s *Slot, m Mutator) { m.Run(s) }

var PDispatch = &Dispatcher{}

type EvilInt int

func (EvilInt) Run(s *Slot) { s.Field = "pwnd" }
