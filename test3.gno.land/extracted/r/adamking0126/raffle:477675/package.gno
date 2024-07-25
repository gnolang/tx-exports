package raffle

require gno.land/r/gc24/raffle

func init() {
	// Set admin address
	o = ownable.NewWithAddress("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")

	partialEntries = make([]*EntryData, 0)
	completeEntries = make([]*EntryData, 0)
	registeredHashes = make(map[string]struct{})
	codeHashes = make([]string, 300)
  RegisterCode("9wfWK9h3mA")
}

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