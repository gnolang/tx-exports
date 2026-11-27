package verification

import "strconv"

// RealmProof verification realm. Stores an auditable, append-only registry of
// evidence hashes. The submitted hash must be calculated off-chain, and the
// realm does not claim that the referenced external assertion is true.
var submissionCount int
var submitted = make(map[string]bool)

// RegisterEvidence rejects malformed or repeated evidence digests.
func RegisterEvidence(_ realm, hash string) int {
    if len(hash) != 64 {
        panic("evidence hash must contain 64 hexadecimal characters")
    }
    for _, ch := range hash {
        if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) {
            panic("evidence hash must be lowercase hexadecimal")
        }
    }
    if submitted[hash] {
        panic("evidence hash already registered")
    }
    submissionCount++
    submitted[hash] = true
    return submissionCount
}

func Count() int {
    return submissionCount
}

func HasEvidence(hash string) bool {
    return submitted[hash]
}

func Render(path string) string {
    heading := "# RealmProof Evidence Registry\n\n"
    if path != "" {
        if !HasEvidence(path) {
            return heading + "Evidence digest not found.\n"
        }
        return heading + "Registered evidence digest: `" + path + "`\n"
    }
    return heading +
        "Registered evidence hashes: " + strconv.Itoa(submissionCount) + "\n\n" +
        "This registry records evidence commitments but does not validate external test results."
}
