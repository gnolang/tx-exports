package cometbls

import (
	"bytes"
	"crypto/cometblszk"
	"encoding/hex"
	"time"

	aibtypes "gno.land/p/aib/ibc/types"
	"gno.land/p/aib/ics23"
	"gno.land/p/nt/ufmt/v0"
)

// verifyHeader verifies a CometBLS Header against the client's state and the
// trusted ConsensusState at header.TrustedHeight. It mirrors Union's
// cometbls verify_header in client.rs, preserving the order of checks and their
// error semantics:
//   - the trusted consensus state must exist for header.TrustedHeight
//   - header revision must match the trusted height revision
//   - the trusted timestamp must be strictly less than the header timestamp
//   - header height must be greater than the trusted height
//   - header time must be within the max clock drift of the current block time
//   - for an adjacent block, the header validators hash must match the trusted
//     next validators hash
//   - the Groth16 proof must verify against the trusted next validators hash
//
// now is the current block time, used for the clock-drift bound.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L185-L254
func (c *CometblsLightClient) verifyHeader(clientState *ClientState, trustedConsensusState *ConsensusState, header *Header, now time.Time) error {
	// The untrusted (signed) header height. CometBLS carries a single revision,
	// so heights are compared against the trusted height's revision height.
	untrustedHeightNumber := header.SignedHeader.Height
	trustedHeightNumber := header.TrustedHeight.RevisionHeight

	if untrustedHeightNumber <= int64(trustedHeightNumber) {
		return errorWithDetails(
			ErrInvalidHeader,
			ufmt.Sprintf("header height <= consensus state height (%d <= %d)", untrustedHeightNumber, trustedHeightNumber),
		)
	}

	trustedTimestamp := trustedConsensusState.GetTimestamp()
	// Normalize to nanoseconds to follow tendermint convention
	untrustedTimestamp := uint64(header.GetTime().UnixNano())

	if untrustedTimestamp <= trustedTimestamp {
		return errorWithDetails(
			ErrInvalidHeaderTimestamp,
			ufmt.Sprintf(
				"trusted header timestamp %d is greater than or equal to the new header timestamp %d",
				trustedTimestamp, untrustedTimestamp,
			),
		)
	}

	currentBlockTime := uint64(now.UnixNano())
	if isClientExpiredAt(trustedTimestamp, clientState.TrustingPeriod, currentBlockTime) {
		return errorWithDetails(
			ErrTrustingPeriodExpired,
			ufmt.Sprintf("trusted consensus state at TrustedHeight %s has expired", header.TrustedHeight),
		)
	}

	maxClockDriftTimestamp, overflow := checkedAddUint64(currentBlockTime, clientState.MaxClockDrift)
	if overflow {
		return errorWithDetails(ErrMathOverflow)
	}

	if untrustedTimestamp >= maxClockDriftTimestamp {
		return errorWithDetails(
			ErrInvalidHeader,
			ufmt.Sprintf("header time >= max drift (%d >= currentTime + %d)", untrustedTimestamp, clientState.MaxClockDrift),
		)
	}

	trustedValidatorsHash := trustedConsensusState.GetNextValidatorsHash()
	// For an adjacent block, the header validators hash must match the trusted
	// next validators hash.
	if untrustedHeightNumber == int64(trustedHeightNumber)+1 &&
		!bytes.Equal(header.SignedHeader.ValidatorsHash, trustedValidatorsHash) {
		return errorWithDetails(
			ErrInvalidHeader,
			ufmt.Sprintf(
				"the validators hash %s doesn't match the trusted validators hash %s for an adjacent block",
				hex.EncodeToString(header.SignedHeader.ValidatorsHash), hex.EncodeToString(trustedValidatorsHash),
			),
		)
	}

	// The trusted next validators hash commits to the validator set that signed
	// the untrusted header; the Groth16 proof attests that they did. SignedHeader
	// is a crypto/cometblszk.LightHeader, so it feeds VerifyZKP directly.
	if err := cometblszk.VerifyZKP(
		clientState.ChainID,
		trustedValidatorsHash,
		*header.SignedHeader,
		header.ZeroKnowledgeProof,
	); err != nil {
		return errorWithDetails(ErrInvalidHeader, "zero-knowledge proof verification failed: "+err.Error())
	}

	return nil
}

func isClientExpiredAt(consensusStateTimestamp uint64, trustingPeriod uint64, now uint64) bool {
	expiresAt, overflow := checkedAddUint64(consensusStateTimestamp, trustingPeriod)
	if overflow {
		return true
	}

	return expiresAt < now
}

func checkedAddUint64(a uint64, b uint64) (uint64, bool) {
	sum := a + b
	if sum < a {
		return 0, true
	}

	return sum, false
}

// verifyMisbehaviour mirrors Union's cometbls verify_misbehaviour in client.rs:
// both headers must independently verify, and the pair is accepted only when it
// matches Union's same-height or non-increasing-time conditions.
// Union reference:
// https://github.com/unionlabs/union/blob/1bb07590230e7c4d071f32ad7185be021a1a1789/cosmwasm/lightclient/cometbls/src/client.rs#L256-L281
func (c *CometblsLightClient) verifyMisbehaviour(misbehaviour *Misbehaviour, now time.Time) error {
	headerA := misbehaviour.Header1
	headerB := misbehaviour.Header2

	if headerA.SignedHeader.Height < headerB.SignedHeader.Height {
		return errorWithDetails(ErrInvalidMisbehaviourHeaderSequence)
	}

	// Regardless of the type of misbehaviour, ensure that both headers are valid
	// and would have been accepted by the light client.
	if err := c.verifyMisbehaviourHeader("Header_1", headerA, now); err != nil {
		return err
	}

	if err := c.verifyMisbehaviourHeader("Header_2", headerB, now); err != nil {
		return err
	}

	if !isMisbehaviourPair(headerA, headerB) {
		return errorWithDetails(ErrMisbehaviourNotFound)
	}

	return nil
}

// isMisbehaviourPair reports whether two independently-valid headers constitute
// accepted misbehaviour, mirroring Union's conditions: at the same height the
// signed headers must be identical; at different heights the earlier-listed
// header must not be strictly newer than the later one.
func isMisbehaviourPair(headerA, headerB *Header) bool {
	if headerA.SignedHeader.Height == headerB.SignedHeader.Height {
		return signedHeadersEqual(headerA.SignedHeader, headerB.SignedHeader)
	}

	return headerA.GetTime().UnixNano() <= headerB.GetTime().UnixNano()
}

func (c *CometblsLightClient) verifyMisbehaviourHeader(label string, header *Header, now time.Time) error {
	prefix := ufmt.Sprintf("verifying %s in Misbehaviour failed: ", label)

	consensusState, found := c.getConsensusState(*header.TrustedHeight)
	if !found {
		return errorWithDetails(
			ErrInvalidMisbehaviour,
			prefix+ufmt.Sprintf("could not get trusted consensus state for Header at TrustedHeight: %s", header.TrustedHeight),
		)
	}

	if err := c.verifyHeader(c.clientState, consensusState, header, now); err != nil {
		return errorWithDetails(ErrInvalidMisbehaviour, prefix+err.Error())
	}

	return nil
}

// signedHeadersEqual reports whether two light headers have identical content.
func signedHeadersEqual(a, b *LightHeader) bool {
	if a == nil || b == nil {
		return a == b
	}

	if a.Height != b.Height || a.TimeSeconds != b.TimeSeconds || a.TimeNanos != b.TimeNanos {
		return false
	}

	return bytes.Equal(a.ValidatorsHash, b.ValidatorsHash) &&
		bytes.Equal(a.NextValidatorsHash, b.NextValidatorsHash) &&
		bytes.Equal(a.AppHash, b.AppHash)
}

// verifyChainedMembershipProof verifies a chain of ICS23 membership proofs.
// Proofs/specs are ordered from the lowest subtree to the root, while keys
// are ordered from the root to the lowest subtree.
//
// Starting at index, each proof must commit to the subroot produced by the
// previous proof (or the initial value). The final derived root must match
// the expected root.
//
// index allows verification to begin after a non-membership proof, using the
// previously computed subroot as the initial value.
func (c *CometblsLightClient) verifyChainedMembershipProof(
	root []byte,
	proofs []ics23.CommitmentProof,
	keys aibtypes.MerklePath,
	value []byte,
	index int,
) error {
	subroot := value
	specs := ics23.GetSDKProofSpecs()

	var err error

	// Start with the provided value. If no proofs remain, subroot is compared
	// directly against the expected root.
	for i := index; i < len(proofs); i++ {
		key := keys.KeyPath[len(keys.KeyPath)-1-i]

		// verify membership of the proof at this index with appropriate key and value
		subroot, err = c.verifyMembershipProofAt(proofs[i], specs[i], key, value, i)
		if err != nil {
			return err
		}

		// Use the computed subroot as the value for the next proof.
		value = subroot
	}

	// Ensure the final chained root matches the expected root.
	if !bytes.Equal(root, subroot) {
		h1, h2 := hex.EncodeToString(root), hex.EncodeToString(subroot)

		return errorWithDetails(
			ErrInvalidProof,
			ufmt.Sprintf("proof did not commit to expected root: %s, got: %s. Please ensure proof was submitted with correct proofHeight and to the correct chain.", h1, h2),
		)
	}

	return nil
}

// verifyMembershipProofAt verifies the existence proof at a single chain index
// and returns its calculated subroot. index is used only for error context.
func (c *CometblsLightClient) verifyMembershipProofAt(proof ics23.CommitmentProof, spec *ics23.ProofSpec, key, value []byte, index int) ([]byte, error) {
	exist := proof.GetExist()
	if exist == nil {
		return nil, errorWithDetails(
			ErrInvalidProof,
			"commitment proof must be existence proof foar verifying membership",
		)
	}

	subroot, err := exist.Calculate()
	if err != nil {
		return nil, errorWithDetails(
			ErrInvalidProof,
			ufmt.Sprintf("could not calculate proof root at index %d, merkle tree may be empty. %v", index, err),
		)
	}

	if err := exist.Verify(spec, subroot, key, value); err != nil {
		return nil, errorWithDetails(
			ErrInvalidProof,
			ufmt.Sprintf("failed to verify membership proof at index %d: %v", index, err),
		)
	}

	return subroot, nil
}
