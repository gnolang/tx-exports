package game32

import (
	"encoding/hex"
	"strconv"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
)

// Public key of the deterministic TEST-ONLY signer (scripts/game29-test-vectors.mjs,
// seed = sha256("gnomoji-game29-test-signer")). Not used anywhere but tests.
const testSignerPub = "faec207b91ab599b1e51652602843fcb52275922e8dab39bed3a21034cece6f1"

func setup() address {
	if admin == address("") {
		admin = testutils.TestAddress("deployer")
		operator = admin
	}
	if len(claimSignerPubKey) != 32 {
		claimSignerPubKey, _ = hex.DecodeString(testSignerPub)
	}
	return admin
}

func ta(name string) address { return testutils.TestAddress(name) }

func bal(a address, coin string) uint64 { return balOf(a.String(), coin) }

// voucher returns (nonce, expiry, sigHex) for a server voucher. Signatures
// come from voucherVectors (generated). A missing vector is logged so the
// generator can sign it, and an invalid signature is returned.
func voucher(t *testing.T, kind string, player address, payload string) (int64, int64, string) {
	nonce := LastNonce(player.String()) + 1
	expiry := time.Now().Unix() + 600
	return nonce, expiry, sigFor(t, kind, player, nonce, expiry, payload)
}

// safeCompactAchPayload wraps compactAchPayload with a recover so that
// cross-kind tests (e.g. signing an "ach" voucher over a claim payload) don't
// crash the test helper. An unparseable payload falls back to the raw string —
// the resulting signature will be wrong and the realm will reject it, which is
// exactly what those rejection tests expect.
func safeCompactAchPayload(payload string) (result string) {
	defer func() {
		if r := recover(); r != nil {
			result = payload // fall back to raw payload on parse error
		}
	}()
	return compactAchPayload(payload)
}

func sigFor(t *testing.T, kind string, player address, nonce, expiry int64, payload string) string {
	// Compact the payload to match the v2 VoucherMessage format.
	compact := payload
	if kind == "claim" {
		compact = compactClaimPayload(payload)
	} else if kind == "ach" {
		compact = safeCompactAchPayload(payload)
	}
	msg := VoucherMessage(kind, player.String(), nonce, expiry, compact)
	if s, ok := voucherVectors[msg]; ok {
		return s
	}
	// Regenerate with: node scripts/game29-test-vectors.mjs
	panic("MISSING_VOUCHER " + hex.EncodeToString([]byte(msg)) + " END")
}

func give(a address, coin string, amt uint64) { creditBal(a.String(), coin, amt) }

func allowanceFor(addr address, r int) uint64 {
	js := ClaimAllowance(addr.String())
	key := `"r` + strconv.Itoa(r) + `":`
	i := strings.Index(js, key) + len(key)
	j := i
	for j < len(js) && js[j] >= '0' && js[j] <= '9' {
		j++
	}
	v, _ := strconv.ParseUint(js[i:j], 10, 64)
	return v
}

func mustAbort(t *testing.T, what string, abort any, wantSub string) {
	if abort == nil {
		t.Errorf("%s: expected abort, got success", what)
		return
	}
	msg := ""
	switch v := abort.(type) {
	case string:
		msg = v
	case error:
		msg = v.Error()
	default:
		msg = "?"
	}
	if wantSub != "" && !strings.Contains(msg, wantSub) {
		t.Errorf("%s: aborted with %q, want it to contain %q", what, msg, wantSub)
	}
}

func h(choice, salt string) string { return moveHash(choice, salt) }

func h0(s string) string {
	x := sha256Sum(s)
	return x
}
