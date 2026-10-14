// Package hlverifier is the launch verifier of bridge/PLAN.md §5.1: the ed25519 check of the signers' signatures
// over a message's Hyperlane checkpoint, under the rule r/hlmailbox keeps beside its signer set — a threshold over
// the set, or §11.13's two groups (one key of group A and one of group B must sign). It registers itself with the
// mailbox at deploy and keeps no state: the signers and the rule are the mailbox's, read at every check, so a
// rotation there is a rotation here. Satisfiable answers whether a signer set could still meet the rule, which is
// what makes a signer's removal at once or a 7-day wait (§5.3).
package hlverifier

import (
	"crypto/ed25519"
	"errors"
	"strconv"

	hl "gno.land/p/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hyperlane/v0"
	"gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlmailbox"
)

const pkgPath = "gno.land/r/g1zdaz6sypk5tdsjc2fzsqrrn4ttn8qzmnl4waqp/hlverifier" // must match gnomod.toml

// verifier is the hlmailbox.Verifier this realm registers.
type verifier struct{}

func init(cur realm) {
	hlmailbox.RegisterVerifier(cross(cur), verifier{})
}

// Verify checks the metadata — Hyperlane's checkpoint head (hook 32 ‖ root 32 ‖ index 4), then 65 bytes a
// signature: the signer's index in the set, then its ed25519 signature over the checkpoint digest of this message
// — and the rule: every signature present must verify, in increasing signer order, and the signers that signed
// must meet the rule.
func (verifier) Verify(origin uint32, metadata, message []byte) error {
	keys, rule := hlmailbox.Signers()
	if len(keys) == 0 {
		return errors.New("hlverifier: no signers")
	}
	m, err := hl.ParseMessage(message)
	if err != nil {
		return err
	}
	if m.Origin != origin {
		return errors.New("hlverifier: the message is from domain " + strconv.FormatUint(uint64(m.Origin), 10) + ", not " + strconv.FormatUint(uint64(origin), 10))
	}
	c, sigs, err := hl.ParseMultisigMetadata(metadata)
	if err != nil {
		return err
	}
	if len(sigs) == 0 {
		return errors.New("hlverifier: no signatures")
	}
	digest := hl.CheckpointDigest(m.Origin, c.Hook, c.Root, c.Index, hl.ID(message))
	var signed []hlmailbox.Key
	last := -1
	for _, s := range sigs {
		i := int(s.Validator)
		if i <= last {
			return errors.New("hlverifier: signatures out of signer order")
		}
		if i >= len(keys) {
			return errors.New("hlverifier: a signature names no signer")
		}
		k := keys[i]
		if !ed25519.Verify(k[:], digest[:], s.Sig[:]) {
			return errors.New("hlverifier: a signature does not verify")
		}
		signed = append(signed, k)
		last = i
	}
	if !satisfies(rule, signed) {
		return errors.New("hlverifier: the signatures do not meet the rule: " + rule.String())
	}
	return nil
}

// Satisfiable is whether a signer set could meet the rule the mailbox keeps now: the threshold many of them, or
// one of each group among them.
func (verifier) Satisfiable(signers []hlmailbox.Key) bool {
	_, rule := hlmailbox.Signers()
	return satisfies(rule, signers)
}

func satisfies(rule hlmailbox.Rule, signed []hlmailbox.Key) bool {
	if rule.TwoGroups() {
		return anyOf(rule.GroupA, signed) && anyOf(rule.GroupB, signed)
	}
	return rule.Threshold >= 1 && len(signed) >= rule.Threshold
}

func anyOf(group, signed []hlmailbox.Key) bool {
	for _, g := range group {
		for _, s := range signed {
			if g == s {
				return true
			}
		}
	}
	return false
}

// Registered is whether the mailbox holds this realm as a verifier.
func Registered() bool { return hlmailbox.VerifierRegistered(pkgPath) }

// Render: the rule enforced now.
func Render(path string) string {
	keys, rule := hlmailbox.Signers()
	active := ""
	if hlmailbox.ActiveVerifier(hlmailbox.LaunchOrigin()) == pkgPath {
		active = "the active verifier"
	} else {
		active = "registered, not the active verifier"
	}
	return "# The ed25519 verifier\n\n" + active + " for origin " + strconv.FormatUint(uint64(hlmailbox.LaunchOrigin()), 10) +
		": " + strconv.Itoa(len(keys)) + " signers in r/hlmailbox under the rule " + rule.String() + "\n"
}
