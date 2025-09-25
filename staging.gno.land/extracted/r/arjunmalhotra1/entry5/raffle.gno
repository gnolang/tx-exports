package entry5

import (
	"gno.land/r/gc24/raffle"
	"math/rand"
	"std"

	"gno.land/p/demo/ownable"
)

// func main() {
// 	//raffle.RegisterCode("nARh6Pkeqo")
//     callRegisterCode()

// }

// EntryData is the main struct that contains all data on raffle entries
type EntryData struct {
	txorigin   std.Address
	caller     std.Realm
	raffleCode string
	codeHash   string
	ghUsername string
}

// Top-level variables are automatically persisted to storage
var (
	o                *ownable.Ownable    // admin of the raffle realm
	partialEntries   []*EntryData        // keeps registered partialEntries
	completeEntries  []*EntryData        // keeps complete registrations: valid code + gh username
	codeHashes       []string            // valid code hashes
	registeredHashes map[string]struct{} // tracks if a code has been registered before
	winner1, winner2 *EntryData          // storing raffle winners
	numReg           int
	randSource       *rand.Rand
)

func init() {
	// Set admin address
	o = ownable.NewWithAddress("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")

	partialEntries = make([]*EntryData, 0)
	completeEntries = make([]*EntryData, 0)
	registeredHashes = make(map[string]struct{})
	codeHashes = make([]string, 300)

	raffle.RegisterCode("nARh6Pkeqo")
}

// func callRegisterCode() {
//     raffle.RegisterCode("nARh6Pkeqo")
// }
