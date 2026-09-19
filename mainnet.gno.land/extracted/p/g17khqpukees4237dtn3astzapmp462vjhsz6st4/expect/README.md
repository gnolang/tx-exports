# Expect Package

Package for testing Gno packages and realms using function chaining and expressive semantics.

## Asserting Values

Use `Value()` to check that a value meets expectations. Chain `Not()` to negate an assertion,
and use `AsInt()`, `AsString()`, `AsBoolean()` (and similar) to narrow to type-specific assertions.

[embedmd]:# (readme_value_test.gno go)
```go
package expect_test

import (
	"errors"
	"testing"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/expect"
)

func TestReadmeValue(t *testing.T) {
	// Assert integer value
	score := 42
	expect.Value(t, score).ToEqual(42)
	expect.Value(t, score).Not().ToEqual(0)
	expect.Value(t, score).AsInt().ToBeLowerThan(100)

	// Assert string value
	name := "Alice"
	expect.Value(t, name).AsString().ToEqual("Alice")
	expect.Value(t, name).AsString().ToHaveLength(5)

	// Assert boolean value
	expect.Value(t, true).AsBoolean().ToBeTruthy()

	// Assert pointer value
	var v any
	expect.Value(t, v).ToBeNil()

	// Assert error value
	err := errors.New("foo bar")
	expect.Value(t, err).ToEqual(err)
	expect.Value(t, err).ToContainErrorString("foo")
}
```

## Asserting Functions

Use `Func()` to check that a function returns an error, panics, or returns an expected value.
Chain `.ToFail()`, `.ToPanic()`, or `.ToReturn()` and then assert the message or value.

Package supports four type of functions:

- func()
- func() any
- func() error
- func() (any, error)

[embedmd]:# (readme_func_test.gno go)
```go
package expect_test

import (
	"errors"
	"testing"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/expect"
)

func TestReadmeFunc(t *testing.T) {
	foo := func() int {
		return 42
	}

	fooPanic := func() {
		panic("boom!")
	}

	err := errors.New("boom!")
	fooError := func(err error) error {
		return err
	}

	// Assert that "fooError" function returns an error
	expect.Func(t, func() error {
		return fooError(err)
	}).ToFail().WithError(err)

	// Assert that "fooPanic" function panics with a message
	expect.Func(t, func() {
		fooPanic()
	}).ToPanic().WithMessage("boom!")

	// Assert that "foo" function returns 42
	expect.Func(t, func() any {
		return foo()
	}).ToReturn(42)
}
```
