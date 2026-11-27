package gnoseal

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// Test addresses. issuerAddr is the project's real deployer address; the
// others are valid bech32 addresses borrowed from the Gno repo's own tests.
var (
	issuerAddr   = address("g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px")
	aliceAddr    = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	bobAddr      = address("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
	strangerAddr = address("g1skl80cuz8zq3lul9pgz5pc35l2pfzgxgfpsqkx")
)

// expectAbort fails the test if fn does not abort with a message
// containing substr. Calls made with cross(cur) panic as aborts, which a
// plain defer/recover cannot catch; uassert uses the VM's revive
// mechanism to capture them.
func expectAbort(t *testing.T, rlm realm, substr string, fn func()) {
	uassert.AbortsContains(t, rlm, substr, fn)
}

// expectLocalPanic is expectAbort for non-crossing calls, whose panics
// stay inside the test's own realm frame.
func expectLocalPanic(t *testing.T, rlm realm, substr string, fn func()) {
	uassert.PanicsContains(t, rlm, substr, fn)
}

func TestCreateAndReadBack(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	base := Count()

	id := CreateCertificate(cross(cur), aliceAddr, "Completed Gno 101", "For finishing the course")
	if id != base+1 {
		t.Fatalf("expected new ID %d, got %d", base+1, id)
	}
	if Count() != base+1 {
		t.Fatalf("expected count %d, got %d", base+1, Count())
	}

	cert := GetCertificate(id)
	if cert.ID != id {
		t.Fatalf("expected cert ID %d, got %d", id, cert.ID)
	}
	if cert.Issuer != issuerAddr {
		t.Fatalf("expected issuer %s, got %s", issuerAddr, cert.Issuer)
	}
	if cert.Recipient != aliceAddr {
		t.Fatalf("expected recipient %s, got %s", aliceAddr, cert.Recipient)
	}
	if cert.Title != "Completed Gno 101" {
		t.Fatalf("unexpected title: %q", cert.Title)
	}
	if cert.Note != "For finishing the course" {
		t.Fatalf("unexpected note: %q", cert.Note)
	}
	if cert.Revoked {
		t.Fatalf("new certificate must not be revoked")
	}
	if cert.RevokeReason != "" {
		t.Fatalf("new certificate must have an empty revoke reason, got %q", cert.RevokeReason)
	}
}

func TestSequentialIDs(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	base := Count()

	id1 := CreateCertificate(cross(cur), aliceAddr, "Course A", "")
	id2 := CreateCertificate(cross(cur), bobAddr, "Course B", "")
	id3 := CreateCertificate(cross(cur), aliceAddr, "Course C", "")
	if id1 != base+1 || id2 != base+2 || id3 != base+3 {
		t.Fatalf("expected sequential IDs %d,%d,%d, got %d,%d,%d",
			base+1, base+2, base+3, id1, id2, id3)
	}
	if Count() != base+3 {
		t.Fatalf("expected count %d, got %d", base+3, Count())
	}
}

func TestInvalidRecipientRejected(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	base := Count()

	expectAbort(t, cur, "invalid recipient address", func() {
		CreateCertificate(cross(cur), address("hello"), "Title", "")
	})
	expectAbort(t, cur, "invalid recipient address", func() {
		CreateCertificate(cross(cur), address(""), "Title", "")
	})
	expectAbort(t, cur, "invalid recipient address", func() {
		CreateCertificate(cross(cur), address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf6"), "Title", "")
	})
	if Count() != base {
		t.Fatalf("rejected creates must not change count: expected %d, got %d", base, Count())
	}
}

func TestEmptyTitleRejected(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	base := Count()

	expectAbort(t, cur, "title must not be empty", func() {
		CreateCertificate(cross(cur), aliceAddr, "", "")
	})
	expectAbort(t, cur, "title must not be empty", func() {
		CreateCertificate(cross(cur), aliceAddr, "   ", "")
	})
	if Count() != base {
		t.Fatalf("rejected creates must not change count: expected %d, got %d", base, Count())
	}
}

func TestFieldLengthLimits(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	base := Count()

	expectAbort(t, cur, "title too long", func() {
		CreateCertificate(cross(cur), aliceAddr, strings.Repeat("a", maxTitleLen+1), "")
	})
	expectAbort(t, cur, "note too long", func() {
		CreateCertificate(cross(cur), aliceAddr, "Title", strings.Repeat("n", maxNoteLen+1))
	})

	// Exactly at the limits must succeed.
	id := CreateCertificate(cross(cur),
		aliceAddr,
		strings.Repeat("a", maxTitleLen),
		strings.Repeat("n", maxNoteLen))
	if id != base+1 {
		t.Fatalf("expected new ID %d, got %d", base+1, id)
	}
	if Count() != base+1 {
		t.Fatalf("expected count %d, got %d", base+1, Count())
	}
}

func TestRevokeByIssuer(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	id := CreateCertificate(cross(cur), aliceAddr, "Hackathon Finalist", "")

	RevokeCertificate(cross(cur), id, "Issued by mistake")

	cert := GetCertificate(id)
	if !cert.Revoked {
		t.Fatalf("certificate %d must be revoked", id)
	}
	if cert.RevokeReason != "Issued by mistake" {
		t.Fatalf("unexpected revoke reason: %q", cert.RevokeReason)
	}
}

func TestRevokeByNonIssuerRejected(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	id := CreateCertificate(cross(cur), aliceAddr, "Course Completion", "")

	testing.SetOriginCaller(strangerAddr)
	expectAbort(t, cur, "only the issuer can revoke", func() {
		RevokeCertificate(cross(cur), id, "I should not be able to do this")
	})

	cert := GetCertificate(id)
	if cert.Revoked {
		t.Fatalf("certificate %d must stay valid after a rejected revoke", id)
	}
}

func TestDoubleRevokeRejected(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	id := CreateCertificate(cross(cur), bobAddr, "Workshop Attendance", "")

	RevokeCertificate(cross(cur), id, "Duplicate entry")
	expectAbort(t, cur, "already revoked", func() {
		RevokeCertificate(cross(cur), id, "Revoking again")
	})

	cert := GetCertificate(id)
	if cert.RevokeReason != "Duplicate entry" {
		t.Fatalf("first revoke reason must stand, got %q", cert.RevokeReason)
	}
}

func TestRevokeNonexistentRejected(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	missing := Count() + 1000

	expectAbort(t, cur, "certificate not found", func() {
		RevokeCertificate(cross(cur), missing, "No such certificate")
	})
	expectLocalPanic(t, cur, "certificate not found", func() {
		GetCertificate(missing)
	})
	expectLocalPanic(t, cur, "certificate not found", func() {
		GetCertificate(0)
	})
}

func TestCertificatesOfIndex(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)

	a1 := CreateCertificate(cross(cur), aliceAddr, "Index A1", "")
	b1 := CreateCertificate(cross(cur), bobAddr, "Index B1", "")
	a2 := CreateCertificate(cross(cur), aliceAddr, "Index A2", "")

	aliceIDs := CertificatesOf(aliceAddr)
	if len(aliceIDs) < 2 {
		t.Fatalf("expected at least 2 certificates for alice, got %d", len(aliceIDs))
	}
	if aliceIDs[len(aliceIDs)-2] != a1 || aliceIDs[len(aliceIDs)-1] != a2 {
		t.Fatalf("expected alice's last two IDs to be %d,%d, got %v", a1, a2, aliceIDs)
	}

	bobIDs := CertificatesOf(bobAddr)
	if len(bobIDs) == 0 || bobIDs[len(bobIDs)-1] != b1 {
		t.Fatalf("expected bob's last ID to be %d, got %v", b1, bobIDs)
	}

	if got := CertificatesOf(strangerAddr); len(got) != 0 {
		t.Fatalf("expected no certificates for stranger, got %v", got)
	}
}
