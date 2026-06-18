package shallowembed

type S0 struct{}
type S1 struct{ S0 }
type S2 struct{ S1 }
type S3 struct{ S2 }
type S4 struct{ S3 }
type S5 struct{ S4 }
type Shallow struct{ S5 }
