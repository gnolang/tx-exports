// Package gnoseal is GnoSeal: verifiable onchain certificates on Gno.land.
//
// Any issuer (a hackathon, course, event, or bounty program) creates a
// completion record for a recipient address. The record is non-transferable,
// publicly verifiable by anyone through this realm's Render pages, and
// revocable only by its original issuer, with the revocation reason written
// on chain.
package gnoseal

import (
	"chain/runtime"
	"strings"
)

// Field length limits, in bytes. They keep certificates small, cheap to
// store, and readable on the Render pages.
const (
	maxTitleLen  = 120
	maxNoteLen   = 560
	maxReasonLen = 280
)

// Certificate is one issued completion record. Certificates are stored by
// sequential ID (starting at 1) and are never deleted; revocation is a flag
// plus a reason, so the full history stays auditable.
type Certificate struct {
	ID           uint64
	Issuer       address
	Recipient    address
	Title        string
	Note         string
	Height       int64 // block height at issuance
	Revoked      bool
	RevokeReason string
}

// Realm state. certs[i] holds the certificate with ID i+1, so slice order is
// issuance order. byRecipient indexes certificate IDs per recipient address
// so Render and queries can list an address's certificates without scanning
// every certificate ever issued.
var (
	certs       []*Certificate
	byRecipient = make(map[address][]uint64)
)

// CreateCertificate issues a new certificate from the caller to recipient
// and returns its sequential ID (the first certificate issued has ID 1).
// The caller, taken from cur.Previous(), is recorded as the issuer; only
// that address can later revoke the certificate.
func CreateCertificate(cur realm, recipient address, title string, note string) uint64 {
	if !recipient.IsValid() {
		panic("gnoseal: invalid recipient address")
	}
	title = strings.TrimSpace(title)
	if len(title) == 0 {
		panic("gnoseal: title must not be empty")
	}
	if len(title) > maxTitleLen {
		panic("gnoseal: title too long")
	}
	if len(note) > maxNoteLen {
		panic("gnoseal: note too long")
	}

	id := uint64(len(certs)) + 1
	cert := &Certificate{
		ID:        id,
		Issuer:    cur.Previous().Address(),
		Recipient: recipient,
		Title:     title,
		Note:      note,
		Height:    runtime.ChainHeight(),
	}
	certs = append(certs, cert)
	byRecipient[recipient] = append(byRecipient[recipient], id)
	return id
}

// RevokeCertificate marks a certificate as revoked and records the reason
// on chain. Only the original issuer may revoke, and only once.
func RevokeCertificate(cur realm, id uint64, reason string) {
	cert := mustCert(id)
	if cur.Previous().Address() != cert.Issuer {
		panic("gnoseal: only the issuer can revoke this certificate")
	}
	if cert.Revoked {
		panic("gnoseal: certificate already revoked")
	}
	reason = strings.TrimSpace(reason)
	if len(reason) == 0 {
		panic("gnoseal: revoke reason must not be empty")
	}
	if len(reason) > maxReasonLen {
		panic("gnoseal: revoke reason too long")
	}
	cert.Revoked = true
	cert.RevokeReason = reason
}

// Count returns the total number of certificates ever issued, including
// revoked ones.
func Count() uint64 {
	return uint64(len(certs))
}

// GetCertificate returns a copy of the certificate with the given ID.
// It panics if no certificate with that ID exists.
func GetCertificate(id uint64) Certificate {
	return *mustCert(id)
}

// CertificatesOf returns the IDs of all certificates issued to recipient,
// in issuance order. The returned slice is a copy.
func CertificatesOf(recipient address) []uint64 {
	ids := byRecipient[recipient]
	out := make([]uint64, len(ids))
	copy(out, ids)
	return out
}

// mustCert returns the stored certificate for id, or panics.
func mustCert(id uint64) *Certificate {
	cert, ok := findCert(id)
	if !ok {
		panic("gnoseal: certificate not found")
	}
	return cert
}

// findCert is the non-panicking lookup used by Render, where a bad ID must
// produce a friendly page instead of an error.
func findCert(id uint64) (*Certificate, bool) {
	if id == 0 || id > uint64(len(certs)) {
		return nil, false
	}
	return certs[id-1], true
}
