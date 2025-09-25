package dao

import (
	"testing"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

func TestSplitRealmURI(t *testing.T) {
	cases := []struct {
		name, uri, realmURI, renderPath string
	}{
		{
			name:     "realm URI",
			uri:      "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
			realmURI: "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
		},
		{
			name:       "realm URI with render path",
			uri:        "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar",
			realmURI:   "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
			renderPath: "foo/bar",
		},
		{
			name:       "realm URI with render path",
			uri:        "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar",
			realmURI:   "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
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
			uri:  "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
			path: "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
		},
		{
			name: "without domain",
			uri:  "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
			path: "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome",
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
