package ptrwrite

var gValue = "original"

func GetPtr() *string { return &gValue }
func GetValue() string { return gValue }
