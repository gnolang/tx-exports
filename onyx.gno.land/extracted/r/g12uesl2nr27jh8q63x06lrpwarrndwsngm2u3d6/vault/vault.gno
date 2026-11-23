package vault

import (
	"chain"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type InvoiceRecord struct {
	Fingerprint  string
	Submitter    string
	Timestamp    int64
	DocumentName string
}

var (
	records = avl.NewTree()
	count   int64
)

// RegisterInvoice adds an invoice fingerprint to the on-chain vault.
func RegisterInvoice(cur realm, fingerprint, docName string) string {
	if len(fingerprint) != 64 {
		panic("fingerprint must be exactly 64 hex characters")
	}
	if records.Has(fingerprint) {
		panic("fingerprint already registered")
	}

	addr := cur.Previous().Address().String()
	ts := time.Now().Unix()

	rec := &InvoiceRecord{
		Fingerprint:  fingerprint,
		Submitter:    addr,
		Timestamp:    ts,
		DocumentName: docName,
	}

	records.Set(fingerprint, rec)
	count++

	chain.Emit("InvoiceRegistered", "fingerprint", fingerprint, "submitter", addr, "doc", docName)
	return ufmt.Sprintf("SUCCESS: registered %s", fingerprint)
}

// GetRecord returns pipe-delimited record info.
func GetRecord(fingerprint string) string {
	val := records.Get(fingerprint)
	if val == nil {
		return ""
	}
	r := val.(*InvoiceRecord)
	return ufmt.Sprintf("%s|%s|%d|%s", r.Fingerprint, r.Submitter, r.Timestamp, r.DocumentName)
}

// HasRecord checks if fingerprint exists.
func HasRecord(fingerprint string) bool {
	return records.Has(fingerprint)
}

// GetCount returns total registered fingerprints.
func GetCount() int64 {
	return count
}

// Render returns markdown view of the vault.
func Render(path string) string {
	if path == "" {
		md := "# Invoice Fingerprint Vault\n\n"
		md += "Proof-of-existence registry for invoice fingerprints on Gno.land.\n\n"
		md += ufmt.Sprintf("- **Total Registered Documents:** %d\n\n", count)
		md += "### Verification Instructions\n"
		md += "Append `/verify/<64-char-hex-hash>` to verify any invoice fingerprint.\n"
		return md
	}

	prefix := "verify/"
	hash := path
	if len(path) > len(prefix) && path[:len(prefix)] == prefix {
		hash = path[len(prefix):]
	}

	if records.Has(hash) {
		val := records.Get(hash)
		r := val.(*InvoiceRecord)
		return ufmt.Sprintf("# Fingerprint Verified\n\n- **Fingerprint:** `%s`\n- **Document:** %s\n- **Submitter:** `%s`\n- **Timestamp:** %d\n- **Status:** VALID ON-CHAIN", r.Fingerprint, r.DocumentName, r.Submitter, r.Timestamp)
	}

	return ufmt.Sprintf("# Not Found\n\nFingerprint `%s` was NOT found in this vault.", hash)
}
