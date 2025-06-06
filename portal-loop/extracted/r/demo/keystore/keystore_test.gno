package keystore

import (
	"std"
	"strings"
	"testing"

	"gno.land/p/demo/testutils"
	"gno.land/p/demo/uassert"
	"gno.land/p/demo/ufmt"
)

func TestRender(t *testing.T) {
	const (
		author1 std.Address = testutils.TestAddress("author1")
		author2 std.Address = testutils.TestAddress("author2")
	)

	tt := []struct {
		caller std.Address
		owner  std.Address
		ps     []string
		exp    string
	}{
		// can set database if the owner is the caller
		{author1, author1, []string{"set", "hello", "gno"}, StatusOK},
		{author1, author1, []string{"size"}, "1"},
		{author1, author1, []string{"set", "hello", "world"}, StatusOK},
		{author1, author1, []string{"size"}, "1"},
		{author1, author1, []string{"set", "hi", "gno"}, StatusOK},
		{author1, author1, []string{"size"}, "2"},
		// only owner can remove
		{author1, author1, []string{"remove", "hi"}, StatusOK},
		{author1, author1, []string{"get", "hi"}, StatusNotFound},
		{author1, author1, []string{"size"}, "1"},
		// add back
		{author1, author1, []string{"set", "hi", "gno"}, StatusOK},
		{author1, author1, []string{"size"}, "2"},

		// different owner has different database
		{author2, author2, []string{"set", "hello", "universe"}, StatusOK},
		// either author can get the other info
		{author1, author2, []string{"get", "hello"}, "universe"},
		// either author can get the other info
		{author2, author1, []string{"get", "hello"}, "world"},
		{author1, author2, []string{"get", "hello"}, "universe"},
		// anyone can view the databases
		{author1, author2, []string{}, `- [g1v96hg6r0wgc47h6lta047h6lta047h6lm33tq6](/r/demo/keystore:g1v96hg6r0wgc47h6lta047h6lta047h6lm33tq6) (2 keys)
- [g1v96hg6r0wge97h6lta047h6lta047h6lyz7c00](/r/demo/keystore:g1v96hg6r0wge97h6lta047h6lta047h6lyz7c00) (1 keys)`},
		// anyone can view the keys in a database
		{author1, author2, []string{""}, `# g1v96hg6r0wge97h6lta047h6lta047h6lyz7c00 database

- 0 [hello](/r/demo/keystore:g1v96hg6r0wge97h6lta047h6lta047h6lyz7c00:get:hello)`},
	}
	for _, tc := range tt {
		p := ""
		if len(tc.ps) > 0 {
			p = tc.owner.String()
			for i, psv := range tc.ps {
				p += ":" + psv
			}
		}
		p = strings.TrimSuffix(p, ":")
		t.Run(p, func(t *testing.T) {
			std.TestSetOriginCaller(tc.caller)
			var act string
			if len(tc.ps) > 0 && tc.ps[0] == "set" {
				act = strings.TrimSpace(Set(tc.ps[1], tc.ps[2]))
			} else if len(tc.ps) > 0 && tc.ps[0] == "remove" {
				act = strings.TrimSpace(Remove(tc.ps[1]))
			} else {
				act = strings.TrimSpace(Render(p))
			}

			uassert.Equal(t, tc.exp, act, ufmt.Sprintf("%v -> '%s'", tc.ps, p))
		})
	}
}
