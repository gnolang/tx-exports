package galcredentials

// AttachHumanProof attaches a human-proof record to a credential: a hash
// and a signature that were verified off-chain (for example an X account
// bound to the owner's wallet, as in Xaverus). The realm stores the
// record and shows it on the credential detail page; it does NOT verify
// the outside account itself, because a Gno realm cannot make HTTP
// calls. Both values are plain strings: the hash is expected in hex
// (e.g. a 64-character sha256 digest) and the signature in base64.
// Only the credential owner may call it (caller from the crossing
// frame). The credential must exist, and the hash must not be empty.
// Attaching again replaces the previous proof. Attaching a proof changes
// nothing else about the credential: not its limits, its spent total,
// or its status.
func AttachHumanProof(cur realm, agent address, proofHash string, proofSig string) {
	if !cur.IsCurrent() {
		panic("not a live realm call")
	}
	cred, ok := credentials[agent]
	if !ok {
		panic("credential not found")
	}
	if cred.Owner != cur.Previous().Address() {
		panic("not credential owner")
	}
	if proofHash == "" {
		panic("human proof hash must not be empty")
	}
	cred.HumanProofHash = proofHash
	cred.HumanProofSig = proofSig
}
