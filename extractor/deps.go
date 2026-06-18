//go:build deps

package main

// Pins the tx-archive module version in go.mod. The blank import is only
// compiled under the `deps` build tag so this package never contributes
// to the real build.
import (
	_ "github.com/gnolang/gno/contribs/tx-archive/backup"
)
