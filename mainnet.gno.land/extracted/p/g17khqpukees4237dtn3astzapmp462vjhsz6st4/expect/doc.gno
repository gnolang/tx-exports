// Package expect provides testing support for packages and realms.
//
// Values can be asserted using the `Value()` function, for example:
//
//	func TestFoo(t *testing.T) {
//	  got := 42
//	  expect.Value(t, got).ToEqual(42)
//	  expect.Value(t, got).Not().ToEqual(0)
//
//	  expect.Value(t, "foo").ToEqual("foo")
//	  expect.Value(t, 42).AsInt().Not().ToBeGreaterThan(50)
//	  expect.Value(t, "TRUE").AsBoolean().ToBeTruthy()
//	}
//
// Functions can also be used to assert returned values, errors or panics.
//
// Package supports four type of functions:
//
//   - func()
//   - func() any
//   - func() error
//   - func() (any, error)
//
// Functions can be asserted using the `Func()` function, for example:
//
//	func TestFoo(t *testing.T) {
//	  expect.Func(t, func() {
//	    panic("Boom!")
//	  }).ToPanic().WithMessage("Boom!")
//
//	  wantErr := errors.New("Boom!")
//	  expect.Func(t, func() error {
//	    return wantErr
//	  }).ToFail().WithMessage("Boom!")
//
//	  expect.Func(t, func() error {
//	    return wantErr
//	  }).ToFail().WithError(wantErr)
//	}
package expect
