// Package veil_verifier is a minimal Phase 0 verification realm for the Veil
// Protocol. It delegates Groth16/BN254 verification to the general-purpose
// groth16 package and records the number of verified proofs.
package veil_verifier

import (
	"strings"

	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/groth16"
)

var (
	verifiedCount uint64
	lastStatus    string
)

// VerifyProof verifies an arbitrary Groth16/BN254 proof given hex-encoded
// verification key, proof points, and comma-separated hex public inputs.
// Panics if verification fails so invalid proof transactions revert.
func VerifyProof(
	cur realm,
	alphaHex string,
	betaHex string,
	gammaHex string,
	deltaHex string,
	icCSV string,
	aHex string,
	bHex string,
	cHex string,
	inputsCSV string,
) string {
	icList := splitCSV(icCSV)
	inputsList := splitCSV(inputsCSV)

	vk, err := groth16.ParseVerifyingKeyHex(alphaHex, betaHex, gammaHex, deltaHex, icList)
	if err != nil {
		panic(err.Error())
	}
	proof, err := groth16.ParseProofHex(aHex, bHex, cHex)
	if err != nil {
		panic(err.Error())
	}
	inputs, err := groth16.ParsePublicInputsHex(inputsList)
	if err != nil {
		panic(err.Error())
	}

	if err := groth16.Verify(vk, proof, inputs); err != nil {
		panic(err.Error())
	}

	verifiedCount++
	lastStatus = "VALID"
	return "VALID"
}

// VerifiedCount returns the number of valid proofs verified by this realm.
func VerifiedCount() uint64 {
	return verifiedCount
}

// Render returns a human-readable summary of the realm state.
func Render(_ string) string {
	return "Veil Protocol Phase 0 Verifier\n\nVerified proofs: " + u64toa(verifiedCount) + "\nLast status: " + lastStatus + "\n"
}

func splitCSV(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	for i := 0; i < len(parts); i++ {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}

func u64toa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
