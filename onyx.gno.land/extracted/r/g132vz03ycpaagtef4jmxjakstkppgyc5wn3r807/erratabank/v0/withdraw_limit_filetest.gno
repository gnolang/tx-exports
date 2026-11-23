// PKGPATH: gno.land/r/test/withdrawfixture/main

package main

import (
	"testing"

	"gno.land/r/g132vz03ycpaagtef4jmxjakstkppgyc5wn3r807/erratabank/v0"
)

func main(cur realm) {
	testing.SetRealm(testing.NewUserRealm(address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")))
	bookID := erratabank.CreateBook(cross(cur), "Book", "First", "https://example.org/book", 1)
	erratabank.Withdraw(cross(cur), bookID, 1)
}

// Error:
// withdrawal must be positive and within available escrow
