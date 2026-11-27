package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const DomainDelegation = "arobi-assurance-delegated-warrant-v1"

// DelegatedWarrant represents a strictly attenuated sub-agent authorization derived
// from an active parent EffectWarrant. A child warrant can NEVER amplify spend, extend
// expiry, switch to an unauthorized action, or redirect to an unauthorized target.
type DelegatedWarrant struct {
	ID                  uint64
	ParentWarrantID     uint64
	ParentWarrantDigest [32]byte
	ParentAgentID       string
	ChildAgentID        string
	Action              string
	Target              string
	MaxSpendUgnot       int64
	IssuedHeight        int64
	ExpiryHeight        int64
}

// Encode serializes DelegatedWarrant into canonical big-endian bytes.
func (d DelegatedWarrant) Encode() []byte {
	out := make([]byte, 0, 192)
	out = appendString(out, DomainDelegation)
	out = append(out, EncodingVersion)
	out = binary.BigEndian.AppendUint64(out, d.ID)
	out = binary.BigEndian.AppendUint64(out, d.ParentWarrantID)
	out = append(out, d.ParentWarrantDigest[:]...)
	out = appendString(out, d.ParentAgentID)
	out = appendString(out, d.ChildAgentID)
	out = appendString(out, d.Action)
	out = appendString(out, d.Target)
	out = binary.BigEndian.AppendUint64(out, uint64(d.MaxSpendUgnot))
	out = binary.BigEndian.AppendUint64(out, uint64(d.IssuedHeight))
	out = binary.BigEndian.AppendUint64(out, uint64(d.ExpiryHeight))
	return out
}

// Digest returns SHA-256(Encode()).
func (d DelegatedWarrant) Digest() [32]byte {
	return sha256.Sum256(d.Encode())
}

// AttenuateWarrant derives a strictly attenuated child warrant from parent.
// Any attempted privilege escalation (spend, TTL, action, or target) fails closed.
func AttenuateWarrant(
	parent EffectWarrant,
	childWarrantID uint64,
	childAgentID string,
	action string,
	target string,
	maxSpendUgnot int64,
	issuedHeight int64,
	expiryHeight int64,
) (DelegatedWarrant, error) {
	if childAgentID == "" {
		return DelegatedWarrant{}, errors.New("childAgentID is required")
	}
	if childAgentID == parent.AgentID {
		return DelegatedWarrant{}, errors.New("cannot delegate warrant to the same agent")
	}
	if maxSpendUgnot < 0 || maxSpendUgnot > parent.MaxSpendUgnot {
		return DelegatedWarrant{}, errors.New("delegation cannot amplify spend ceiling above parent warrant")
	}
	if issuedHeight < parent.IssuedHeight {
		return DelegatedWarrant{}, errors.New("delegation issuedHeight precedes parent warrant")
	}
	if expiryHeight < issuedHeight || expiryHeight > parent.ExpiryHeight {
		return DelegatedWarrant{}, errors.New("delegation cannot extend expiry beyond parent warrant")
	}
	if parent.Action != "" && action != parent.Action {
		return DelegatedWarrant{}, errors.New("delegation cannot escalate to different action: " + action)
	}
	if parent.Target != "" && target != parent.Target {
		return DelegatedWarrant{}, errors.New("delegation cannot redirect target from " + parent.Target + " to " + target)
	}
	return DelegatedWarrant{
		ID:                  childWarrantID,
		ParentWarrantID:     parent.ID,
		ParentWarrantDigest: parent.Digest(),
		ParentAgentID:       parent.AgentID,
		ChildAgentID:        childAgentID,
		Action:              action,
		Target:              target,
		MaxSpendUgnot:       maxSpendUgnot,
		IssuedHeight:        issuedHeight,
		ExpiryHeight:        expiryHeight,
	}, nil
}

// VerifyAgainst checks that this DelegatedWarrant is a valid, non-amplified attenuation of parent.
func (d DelegatedWarrant) VerifyAgainst(parent EffectWarrant) error {
	if d.ParentWarrantID != parent.ID {
		return errors.New("parent warrant ID mismatch")
	}
	if d.ParentWarrantDigest != parent.Digest() {
		return errors.New("parent warrant digest mismatch")
	}
	if d.ParentAgentID != parent.AgentID {
		return errors.New("parent agent ID mismatch")
	}
	if d.MaxSpendUgnot < 0 || d.MaxSpendUgnot > parent.MaxSpendUgnot {
		return errors.New("delegated spend exceeds parent warrant ceiling")
	}
	if d.ExpiryHeight > parent.ExpiryHeight || d.ExpiryHeight < d.IssuedHeight {
		return errors.New("delegated expiry exceeds parent warrant lifetime")
	}
	if parent.Action != "" && d.Action != parent.Action {
		return errors.New("delegated action does not match parent warrant")
	}
	if parent.Target != "" && d.Target != parent.Target {
		return errors.New("delegated target does not match parent warrant")
	}
	return nil
}
