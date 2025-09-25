package gnome

import (
	"fmt"
	"testing"
)

func TestPaginator(t *testing.T) {
	items := []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	cases := []struct {
		name, uri, prevPath, nextPath    string
		offset, pageSize, page, lastPage int
		pageItems                        string
		stopped, enabled, isLastPage     bool
	}{
		{
			name:      "page 1",
			uri:       "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=1:foo=bar",
			enabled:   true,
			nextPath:  "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=2:foo=bar",
			offset:    0,
			pageSize:  5,
			page:      1,
			lastPage:  2,
			pageItems: "[1 2 3 4 5]",
		},
		{
			name:       "page 2",
			uri:        "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=2:foo=bar",
			enabled:    true,
			prevPath:   "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=1:foo=bar",
			nextPath:   "",
			offset:     5,
			pageSize:   5,
			page:       2,
			lastPage:   2,
			pageItems:  "[6 7 8 9 10]",
			isLastPage: true,
		},
		{
			name:      "missing page",
			uri:       "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=3:foo=bar",
			enabled:   true,
			prevPath:  "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=2:foo=bar",
			nextPath:  "/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=4:foo=bar",
			offset:    10,
			pageSize:  5,
			page:      3,
			lastPage:  2,
			pageItems: "[]",
			stopped:   true,
		},
		{
			name:      "invalid page number",
			uri:       "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=0:foo=bar",
			enabled:   false,
			prevPath:  "",
			nextPath:  "",
			offset:    0,
			pageSize:  4,
			page:      0,
			lastPage:  3,
			pageItems: "[]",
			stopped:   true,
		},
		{
			name:      "invalid page value",
			uri:       "gno.land/r/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome:foo/bar:page=foo:foo=bar",
			enabled:   false,
			prevPath:  "",
			nextPath:  "",
			offset:    0,
			pageSize:  2,
			page:      0,
			lastPage:  5,
			pageItems: "[]",
			stopped:   true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			var pageItems []int

			// Act
			p := NewPaginator(tc.uri, WithPageSize(tc.pageSize), WithItemCount(len(items)))

			// Assert
			if got := p.Page(); got != tc.page {
				t.Fatalf("expected page: %d, got: %d", tc.page, got)
			}

			if got := p.LastPage(); got != tc.lastPage {
				t.Fatalf("expected last page: %d, got: %d", tc.lastPage, got)
			}

			if got := p.PrevPageURI(); got != tc.prevPath {
				t.Fatalf("expected prev page path: '%s', got: '%s'", tc.prevPath, got)
			}

			if got := p.NextPageURI(); got != tc.nextPath {
				t.Fatalf("expected next page path: '%s', got: '%s'", tc.nextPath, got)
			}

			if got := p.Offset(); got != tc.offset {
				t.Fatalf("expected offset: %d, got: %d", tc.offset, got)
			}

			if got := p.PageSize(); got != tc.pageSize {
				t.Fatalf("expected page size: %d, got: %d", tc.pageSize, got)
			}

			if got := p.IsEnabled(); got != tc.enabled {
				t.Fatalf("expected enabled: %v, got: %v", tc.enabled, got)
			}

			if got := p.IsLastPage(); got != tc.isLastPage {
				t.Fatalf("expected is last page to be: %v, got: %v", tc.isLastPage, got)
			}

			stopped := p.Iterate(func(i int) bool {
				if i >= len(items) {
					return true
				}

				pageItems = append(pageItems, items[i])
				return false
			})
			if stopped != tc.stopped {
				t.Fatalf("expected iteration result: %v, got: %v", tc.stopped, stopped)
			}

			if got := fmt.Sprintf("%v", pageItems); got != tc.pageItems {
				t.Fatalf("expected page items: %s, got: %s", tc.pageItems, got)
			}
		})
	}
}
