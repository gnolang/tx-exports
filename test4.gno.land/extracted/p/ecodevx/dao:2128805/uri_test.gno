package dao

import (
	"testing"

	gnome "gno.land/p/ecodevx/dao"
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
