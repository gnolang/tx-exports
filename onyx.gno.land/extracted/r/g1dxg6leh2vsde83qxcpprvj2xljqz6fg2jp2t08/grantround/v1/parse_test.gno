package grantround

import (
	"testing"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/uassert/v0"
)

func TestParseRule(t *testing.T) {
	r, err := parseRule("weighted", " security:3 ,idioms:10", 2, "lowest", "why")
	uassert.NoError(t, err)
	uassert.True(t, r.Method == rulecalc.WeightedSum)
	uassert.True(t, r.Tie == rulecalc.LowestID)
	uassert.Equal(t, 2, len(r.Criteria))
	uassert.Equal(t, "security", r.Criteria[0].Name)
	uassert.Equal(t, 10, r.Criteria[1].Weight)
	uassert.Equal(t, 2, r.Quorum)

	for _, bad := range []string{"", "a", "a:", ":3", "a:x", "a:1:2", "a:1,,b:2"} {
		_, err := parseRule("weighted", bad, 1, "lowest", "")
		uassert.Error(t, err, "criteria "+bad)
	}
	_, err = parseRule("other", "a:1", 1, "lowest", "")
	uassert.Error(t, err)
	_, err = parseRule("majority", "a:1", 1, "other", "")
	uassert.Error(t, err)
}

func TestParseApps(t *testing.T) {
	apps, err := parseApps(testAppsEncoded())
	uassert.NoError(t, err)
	uassert.Equal(t, 2, len(apps))
	uassert.Equal(t, "Beta", apps[1].Title)
	uassert.Equal(t, p0, apps[0].Payout)
	for _, bad := range []string{"", "A|p", "A|p|notanaddress", "|p|" + p0.String(), "A||" + p0.String(), "A|p|" + p0.String() + "|x"} {
		_, err := parseApps(bad)
		uassert.Error(t, err, "apps "+bad)
	}
}

func TestParseScores(t *testing.T) {
	s, err := parseScores("5,5; 6,0")
	uassert.NoError(t, err)
	uassert.Equal(t, 2, len(s))
	uassert.Equal(t, 6, s[1][0])
	for _, bad := range []string{"", "5,x", "5,,5", "5,5;", ";5"} {
		_, err := parseScores(bad)
		uassert.Error(t, err, "scores "+bad)
	}
}
