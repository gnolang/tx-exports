package urim

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"gno.land/p/g1efejv30mcyz2tglm36263ha83ttv4zfu0gnnq0/hat/v0"
)

// Message returns the exact bytes a participant signs for a call:
//
//	urim/v1 \n <draw id> \n <phase> \n <hex sha256(payload)> \n <nonce>
//
// where payload is the action name and the call's fields joined by "\n".
// Phones build the same bytes in web/lib/protocol.ts.
func Message(id int64, phase hat.Phase, nonce int64, fields ...string) []byte {
	sum := sha256.Sum256([]byte(strings.Join(fields, "\n")))
	return []byte("urim/v1\n" + strconv.FormatInt(id, 10) + "\n" + phase.String() + "\n" +
		hex.EncodeToString(sum[:]) + "\n" + strconv.FormatInt(nonce, 10))
}

// verifySig panics unless sig (hex) is pub's Ed25519 signature of the
// message for these fields. Verification happens here, in the realm.
func verifySig(pub []byte, id int64, phase hat.Phase, nonce int64, sig string, fields ...string) {
	s := mustHex("sig", sig, 64)
	if !ed25519.Verify(pub, Message(id, phase, nonce, fields...), s) {
		panic("urim: bad signature")
	}
}

func mustHex(what, s string, size int) []byte {
	if len(s) != 2*size || strings.ToLower(s) != s {
		panic("urim: " + what + " must be " + strconv.Itoa(size) + " bytes of lowercase hex")
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("urim: " + what + " is not hex")
	}
	return b
}

func mustB64(what, s string) []byte {
	if len(s) > base64.StdEncoding.EncodedLen(hat.MaxBlob) {
		panic("urim: " + what + " is too large")
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		panic("urim: " + what + " is not base64")
	}
	// Exactly one encoding per blob, so a signed string means one thing.
	if base64.StdEncoding.EncodeToString(b) != s {
		panic("urim: " + what + " is not canonical base64")
	}
	return b
}

func splitB64(items string, n int) [][]byte {
	parts := strings.Split(items, ",")
	if len(parts) > n+1 {
		// Room for one extra so the hat can report "slip count changed";
		// anything larger is not worth decoding.
		panic("urim: too many items")
	}
	out := make([][]byte, len(parts))
	for k, p := range parts {
		out[k] = mustB64("item", p)
	}
	return out
}

// checkText rejects text that is too long, not UTF-8, or has control
// characters or markup brackets. Render escapes the rest.
func checkText(what, s string, min, max int) {
	if len(s) < min || len(s) > max {
		panic("urim: " + what + " must be " + strconv.Itoa(min) + " to " + strconv.Itoa(max) + " bytes")
	}
	if !utf8.ValidString(s) {
		panic("urim: " + what + " is not UTF-8")
	}
	for _, r := range s {
		if unicode.IsControl(r) || r == '<' || r == '>' || r == '\\' || r == '"' {
			panic("urim: " + what + " has a character that is not allowed")
		}
	}
	if strings.TrimSpace(s) != s {
		panic("urim: " + what + " has leading or trailing spaces")
	}
}

// checkName allows letters, digits, spaces and . - ' only.
func checkName(name string) {
	checkText("name", name, 1, 40)
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != ' ' && r != '.' && r != '-' && r != '\'' {
			panic("urim: names may use letters, digits, spaces and . - ' only")
		}
	}
}

func sameName(a, b string) bool { return strings.EqualFold(a, b) }

func bytesEq(a, b []byte) bool { return string(a) == string(b) }

func sha256Sum(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}
