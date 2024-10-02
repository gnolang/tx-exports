package router

import (
	"fmt"
	"testing"

	router "gno.land/p/ecodevx/router"
)

func TestSplitRenderPath(t *testing.T) {
	cases := []struct {
		name, renderPath, prefix, route, args string
	}{
		{
			name:       "prefix path",
			renderPath: "/foo",
			prefix:     "foo",
			args:       "[]",
		},
		{
			name:       "path with short route",
			renderPath: "/foo/bar",
			prefix:     "foo",
			route:      "bar",
			args:       "[]",
		},
		{
			name:       "path with long route",
			renderPath: "/foo/bar/baz",
			prefix:     "foo",
			route:      "bar/baz",
			args:       "[]",
		},
		{
			name:       "full path with one arg",
			renderPath: "/foo/bar/baz:arg=value",
			prefix:     "foo",
			route:      "bar/baz",
			args:       "[arg=value]",
		},
		{
			name:       "full path with multiple args",
			renderPath: "/foo/bar/baz:arg1=value1:arg2=value2",
			prefix:     "foo",
			route:      "bar/baz",
			args:       "[arg1=value1 arg2=value2]",
		},
		{
			name: "empty path",
			args: "[]",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			prefix, route, args := router.SplitRenderPath(tc.renderPath)

			// Assert
			if prefix != tc.prefix {
				t.Fatalf("expected prefix: '%s', got: '%s'", tc.prefix, prefix)
			}

			if route != tc.route {
				t.Fatalf("expected route: '%s', got: '%s'", tc.route, route)
			}

			if got := fmt.Sprintf("%v", args); got != tc.args {
				t.Fatalf("expected arguments: %s, got: %s", tc.args, got)
			}
		})
	}
}

func TestRouterRender(t *testing.T) {
	cases := []struct {
		name, renderPath, prefix, route, args string
		notFound                              bool
	}{
		{
			name:       "prefix path",
			renderPath: "/foo",
			prefix:     "foo",
			args:       "[]",
		},
		{
			name:       "path with short route",
			renderPath: "/foo/bar",
			prefix:     "foo",
			route:      "bar",
			args:       "[]",
		},
		{
			name:       "path with long route",
			renderPath: "/foo/bar/baz",
			prefix:     "foo",
			route:      "bar/baz",
			args:       "[]",
		},
		{
			name:       "full path with multiple args",
			renderPath: "/foo/bar/baz:arg1=value1:arg2=value2",
			prefix:     "foo",
			route:      "bar/baz",
			args:       "[arg1=value1 arg2=value2]",
		},
		{
			name:       "missing path",
			renderPath: "/test",
			notFound:   true,
		},
		{
			name:     "empty path",
			notFound: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Arrange
			var (
				request       router.Request
				successOutput = "OK"
				r             = router.New()
			)

			r.HandleFunc("foo", func(res router.ResponseWriter, req router.Request) {
				request = req
				res.Write(successOutput)
			})

			// Act
			output := r.Render(tc.renderPath)

			// Assert
			if tc.notFound {
				if output == successOutput {
					t.Fatal("expected request to fail")
				}

				// Run the next test
				continue
			}

			if output != successOutput {
				t.Fatalf("expected output: '%s', got: '%s'", successOutput, output)
			}

			if request.Path != tc.renderPath {
				t.Fatalf("expected request path: '%s', got: '%s'", tc.renderPath, request.Path)
			}

			if request.Prefix != tc.prefix {
				t.Fatalf("expected request prefix: '%s', got: '%s'", tc.prefix, request.Prefix)
			}

			if request.Route != tc.route {
				t.Fatalf("expected request route: '%s', got: '%s'", tc.route, request.Route)
			}

			if got := fmt.Sprintf("%v", request.Args); got != tc.args {
				t.Fatalf("expected request arguments: %s, got: %s", tc.args, got)
			}
		})
	}
}
