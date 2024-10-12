package dao

import (
	"testing"

	gnome "gno.land/p/gnome/dao"
)

func TestSplitRealmURI(t *testing.T) {
	cases := []struct {
		name, uri, realmURI, renderPath string
	}{
		{
			name:     "realm URI",
			uri:      "gno.land/r/gnome",
			realmURI: "gno.land/r/gnome",
		},
		{
			name:       "realm URI with render path",
			uri:        "gno.land/r/gnome:foo/bar",
			realmURI:   "gno.land/r/gnome",
			renderPath: "foo/bar",
		},
		{
			name:       "realm URI with render path",
			uri:        "gno.land/r/gnome:foo/bar",
			realmURI:   "gno.land/r/gnome",
			renderPath: "foo/bar",
		},
		{
			name: "empty URI",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			realmURI, renderPath := gnome.SplitRealmURI(tc.uri)

			// Assert
			if realmURI != tc.realmURI {
				t.Fatalf("expected realm URI: '%s', got: '%s'", tc.realmURI, realmURI)
			}

			if renderPath != tc.renderPath {
				t.Fatalf("expected render path: '%s', got: '%s'", tc.renderPath, renderPath)
			}
		})
	}
}

func TestCutRealmDomain(t *testing.T) {
	cases := []struct {
		name, uri, path string
	}{
		{
			name: "with domain",
			uri:  "gno.land/r/gnome",
			path: "/r/gnome",
		},
		{
			name: "without domain",
			uri:  "/r/gnome",
			path: "/r/gnome",
		},
		{
			name: "empty",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			path := gnome.CutRealmDomain(tc.uri)

			// Assert
			if path != tc.path {
				t.Fatalf("expected path: '%s', got: '%s'", tc.path, path)
			}
		})
	}
}
