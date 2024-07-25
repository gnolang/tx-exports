package raffle

import (
	"crypto/sha256"
	"encoding/hex"
	"math/rand"
	"std"
	"strings"

	"gno.land/p/demo/ownable"
	"gno.land/p/demo/ufmt"
	"gno.land/r/gc24/raffle"
)

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

// Nothing to see here, just some constants, move on :)
const (
	codeLength = 10
	amtOfCodes = 300
)

// Hello! This is where you register your raffle code!
// Calling RegisterCode is the first step for entering the raffle.
// It allows you to register a specific raffle code and connect your address to it.
// RegisterCode only be called via other code; you should figure out a way to do it.
func RegisterCode(code string) string {
	if code == "" && len(code) != codeLength {
		panic("invalid code: " + code)
	}

	caller := std.PrevRealm()     // save realm used to call
	origin := std.GetOrigCaller() // save deployer of realm

	// Deny non-code entries
	if caller.IsUser() {
		panic("denied; can only be called from within code")
	}

	// Get sha256 of code
	hash := sha256.Sum256([]byte(code))
	hashString := hex.EncodeToString(hash[:])

	// Check if code has already been registered
	if _, ok := registeredHashes[hashString]; ok {
		panic("code already registered: " + code)
	}

	// Check if the gopher has already registered another raffle code
	if originExists(origin) {
		panic("you cannot register more than one code!")
	}

	// Try to find the hash in the official hash list
	var found bool
	for _, ch := range codeHashes {
		if ch == hashString {
			found = true
			break
		}
	}

	if !found {
		panic("specified code is not a valid raffle code: " + code)
	}

	entry := &EntryData{
		txorigin:   origin,
		caller:     caller,
		raffleCode: code,
		codeHash:   hashString,
		ghUsername: "",
	}

	// Save to hash tracker
	registeredHashes[hashString] = struct{}{}

	// Save raffle entry
	partialEntries = append(partialEntries, entry)

	return ufmt.Sprintf("Successfully registered raffle code!\n%s\nRegister your username to complete your raffle entry.", entry.String())
}

// Somewhat similar to Go, init() executes upon deployment of your code.
// Hint: maybe you can use init() in your code to execute RegisterCode() upon deployment via play.gno.land?
func init() {
	// Set admin address
	o = ownable.NewWithAddress("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")

	partialEntries = make([]*EntryData, 0)
	completeEntries = make([]*EntryData, 0)
	registeredHashes = make(map[string]struct{})
	codeHashes = make([]string, 300)
	RegisterCode("9wfWK9h3mA")
}

// RegisterUsername registers a GitHub username to an already existing entry
// Hint: you can call this function just like you did with RegisterCode(), or via gno.studio/connect :)
// If you use Connect, make sure you're on the Portal Loop network, and you've navigated to the correct path!
func RegisterUsername(username string) string {
	if username == "" {
		panic("invalid username: " + username)
	}

	origin := std.GetOrigCaller()

	for _, entry := range partialEntries {
		if entry.txorigin == origin { // this will check if you're using the same address as when registering the raffle code ;)
			if entry.ghUsername != "" {
				panic("you cannot register your username twice!")
			}

			entry.ghUsername = username
			completeEntries = append(completeEntries, entry)
			numReg += 1
			return ufmt.Sprintf("successfully registered %s for address %s", username, entry.txorigin)
		}
	}

	panic("could not find entry for caller address; did you register your raffle code yet?")
}

// Admin stuff

func PickWinner1() string {
	o.AssertCallerIsOwner()
	winner1 = pickWinner()

	return winner1.ghUsername
}

func PickWinner2() string {
	o.AssertCallerIsOwner()
	winner2 = pickWinner()

	return winner2.ghUsername
}

func UploadCodeHashes(delimCodes string) {
	o.AssertCallerIsOwner()

	tokens := strings.Split(delimCodes, ",")

	if len(tokens) != amtOfCodes {
		panic(ufmt.Sprintf("invalid amount of codes; wanted %d got %d", amtOfCodes, len(tokens)))
	}

	copy(codeHashes, tokens)
}

func UploadRandomness(x, y uint64) {
	o.AssertCallerIsOwner()

	randSource = rand.New(rand.NewPCG(x, y))
}

// Rendering

func Render(_ string) string {
	output := "# Raffle - GopherCon US 2024\n\n"

	output += renderStats()

	if winner1 != nil || winner2 != nil {
		output += renderWinners()
	}

	output += RenderGuide()

	return output
}

func renderStats() string {
	output := ""

	output += "### Raffle Stats\n\n"

	output += `<div class="columns-3">`

	output += `<div class="column">` // Latest codes
	output += renderLatestCodesWidget(5)
	output += `</div>` // close Latest codes

	output += `<div class="column">` // Latest usernames
	output += renderLatestUsernamesWidget(5)
	output += `</div>` // close Latest usernames

	output += `<div class="column">` // Chances
	output += renderChances()
	output += `</div>` // close Chances

	output += `</div>` // close columns-3

	output += "\n\n"
	output += "---" // close section

	output += "\n"

	return output
}

func renderChances() string {
	output := "\n\n#### Chances\n\n"

	output += ufmt.Sprintf("- Users in the raffle: %d\n\n", numReg)

	if numReg > 0 {
		output += ufmt.Sprintf("- Chance of winning: 2:%d\n\n", numReg)
	}

	return output
}

func renderLatestCodesWidget(amt int) string {
	output := "\n\n#### Latest codes\n\n"
	peNum := len(partialEntries)

	if peNum == 0 {
		output += "No codes registered yet."
		return output
	}

	if peNum < amt {
		amt = peNum
	}

	for i := peNum - 1; i >= peNum-amt; i-- {
		output += ufmt.Sprintf("- `%s`\n\n", partialEntries[i].raffleCode)
	}

	return output
}

func renderLatestUsernamesWidget(amt int) string {
	output := "\n\n#### Latest usernames\n\n"
	ceNum := len(completeEntries)

	if winner1 != nil || winner2 != nil {
		output += "Winners are chosen!"
		return output
	}

	if ceNum == 0 {
		output += "No usernames registered yet."
		return output
	}

	if ceNum < amt {
		amt = ceNum
	}

	for i := ceNum - 1; i >= ceNum-amt; i-- {
		output += ufmt.Sprintf("- `%s`\n\n", completeEntries[i].ghUsername)
	}

	return output
}

func renderWinners() string {
	output := "\n\n# Winners\n\n"

	if winner1 != nil {
		output += ufmt.Sprintf("### Winner 1: `@%s`\n\n", winner1.ghUsername)
	}

	if winner2 != nil {
		output += ufmt.Sprintf("### Winner 2: `@%s`\n\n", winner2.ghUsername)
	}

	output += "## Congratulations! Come to the booth and show us your GitHub account!\n\n"

	output += "---\n\n"

	return output
}

// Helpers

func (entry *EntryData) String() string {
	return ufmt.Sprintf("Address: %s\nRealm Path: %s\nCode: %s\nHash: %s\nGitHub username: %s\n",
		entry.txorigin.String(),
		entry.caller.PkgPath(),
		entry.raffleCode,
		entry.codeHash,
		entry.ghUsername,
	)
}

func pickWinner() *EntryData {
	if len(completeEntries) == 0 {
		panic("No complete entries yet!")
	}
	if randSource == nil {
		panic("No randomness source yet!")
	}

	r := rand.New(randSource)
	winnerIndex := r.IntN(len(completeEntries))
	winner := completeEntries[winnerIndex]

	// remove winner from entry list
	completeEntries = append(completeEntries[:winnerIndex], completeEntries[winnerIndex+1:]...)

	return winner
}

func CheckHashUpload() int {
	return len(codeHashes)
}

func originExists(origin std.Address) bool {
	for _, e := range partialEntries {
		if e.txorigin == origin {
			return true
		}
	}

	return false
}
