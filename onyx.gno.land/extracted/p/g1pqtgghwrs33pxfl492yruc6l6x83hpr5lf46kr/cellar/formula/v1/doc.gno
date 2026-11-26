// Package formula is the calculation engine behind Cellar.
//
// It parses spreadsheet formulas such as
//
//	=ROUND(SUM(B2:B9) * rates!C$1, 2)
//
// and evaluates them against any grid that implements [Book]. The package
// holds no state and imports nothing but the standard library, so any realm
// can use it on its own data.
//
// # Numbers
//
// A number is an int64 count of millionths ([Num]). Addition and subtraction
// are exact; multiplication and division are rounded to the nearest millionth,
// halves away from zero. A result that does not fit is the error value #NUM!,
// never a wrapped or approximated number. One millionth is also one ugnot, so
// a GNOT amount is always exact.
//
// # Errors are values
//
// Evaluation does not panic on user input. A bad operand, a missing cell, a
// circular reference or too much work each produce an error value (#VALUE!,
// #REF!, #CYCLE!, #LIMIT!, ...) that flows through the formulas that use it.
package formula
