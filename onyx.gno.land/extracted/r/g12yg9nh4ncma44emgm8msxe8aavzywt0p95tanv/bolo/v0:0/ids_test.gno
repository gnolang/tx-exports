package bolo

import "testing"

func TestParseID(t *testing.T) {
	for _, s := range []string{"1", "7", "42", "18446744073709551615"} {
		id, ok := parseID(s)
		if !ok || idString(id) != s {
			t.Errorf("parseID(%q) = %d, %t; want %s", s, uint64(id), ok, s)
		}
	}
	// One ID, one spelling (API C9, INV-18): anything else names no campaign.
	for _, s := range []string{
		"", "0", "00", "042", "+42", "-1", " 42", "42 ", "4 2", "4.2", "0x2a", "1e3",
		"18446744073709551616", "99999999999999999999", "123456789012345678901",
		"４２", "٤٢",
	} {
		if id, ok := parseID(s); ok {
			t.Errorf("parseID(%q) = %d; want no campaign", s, uint64(id))
		}
	}
}
