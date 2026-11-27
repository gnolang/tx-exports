package gnoseal

import (
	"strconv"
	"strings"
	"testing"
)

func TestRenderHome(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	id := CreateCertificate(cross(cur), aliceAddr, "Render Home Marker", "")

	out := Render("")
	if !strings.Contains(out, "# GnoSeal") {
		t.Fatalf("home page must carry the GnoSeal heading, got:\n%s", out)
	}
	if !strings.Contains(out, "Render Home Marker") {
		t.Fatalf("home page must list the new certificate's title, got:\n%s", out)
	}
	link := ":cert/" + strconv.FormatUint(id, 10)
	if !strings.Contains(out, link) {
		t.Fatalf("home page must link to %s, got:\n%s", link, out)
	}
}

func TestRenderCertDetail(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	id := CreateCertificate(cross(cur), aliceAddr, "Render Detail Marker", "A note worth showing")
	path := "cert/" + strconv.FormatUint(id, 10)

	out := Render(path)
	if !strings.Contains(out, "Render Detail Marker") {
		t.Fatalf("detail page must show the title, got:\n%s", out)
	}
	if !strings.Contains(out, aliceAddr.String()) {
		t.Fatalf("detail page must show the recipient, got:\n%s", out)
	}
	if !strings.Contains(out, issuerAddr.String()) {
		t.Fatalf("detail page must show the issuer, got:\n%s", out)
	}
	if !strings.Contains(out, "A note worth showing") {
		t.Fatalf("detail page must show the note, got:\n%s", out)
	}
	if !strings.Contains(out, "Valid") {
		t.Fatalf("detail page must show the certificate as Valid, got:\n%s", out)
	}
	if strings.Contains(out, "Revoked") {
		t.Fatalf("detail page of a valid certificate must not say Revoked, got:\n%s", out)
	}

	RevokeCertificate(cross(cur), id, "Rendered revocation reason")
	out = Render(path)
	if !strings.Contains(out, "Revoked") {
		t.Fatalf("detail page must show the certificate as Revoked after revocation, got:\n%s", out)
	}
	if !strings.Contains(out, "Rendered revocation reason") {
		t.Fatalf("detail page must show the revoke reason, got:\n%s", out)
	}
}

func TestRenderAddrPage(cur realm, t *testing.T) {
	testing.SetOriginCaller(issuerAddr)
	CreateCertificate(cross(cur), bobAddr, "Render Addr Marker", "")

	out := Render("addr/" + bobAddr.String())
	if !strings.Contains(out, "Render Addr Marker") {
		t.Fatalf("address page must list the recipient's certificate, got:\n%s", out)
	}
	if !strings.Contains(out, bobAddr.String()) {
		t.Fatalf("address page must name the address, got:\n%s", out)
	}

	out = Render("addr/" + strangerAddr.String())
	if !strings.Contains(out, "No certificates") {
		t.Fatalf("address page for an address without certificates must say so, got:\n%s", out)
	}

	out = Render("addr/not-an-address")
	if !strings.Contains(out, "not a valid Gno address") {
		t.Fatalf("address page must reject an invalid address, got:\n%s", out)
	}
}

func TestRenderUnknownPages(cur realm, t *testing.T) {
	missing := "cert/" + strconv.FormatUint(Count()+1000, 10)
	out := Render(missing)
	if !strings.Contains(out, "Certificate not found") {
		t.Fatalf("unknown certificate page must say not found, got:\n%s", out)
	}

	out = Render("cert/not-a-number")
	if !strings.Contains(out, "Certificate not found") {
		t.Fatalf("non-numeric certificate page must say not found, got:\n%s", out)
	}

	out = Render("something/else")
	if !strings.Contains(out, "Unknown page") {
		t.Fatalf("unknown route must say unknown page, got:\n%s", out)
	}
}
