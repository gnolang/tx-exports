// Package tessespike is a throwaway Phase 1 realm used to time a dependent gpao approval.
package tessespike

import ts "gno.land/p/g1e8twylmkrc6zexu3mpueuah2xu7t7h085x8acy/tessespike/v0"

var board = ts.NewBoard()

func Bump(cur realm) {
	board.Bump()
}

func Render(_ string) string {
	return "# Tesse spike\n\n" + board.String()
}
