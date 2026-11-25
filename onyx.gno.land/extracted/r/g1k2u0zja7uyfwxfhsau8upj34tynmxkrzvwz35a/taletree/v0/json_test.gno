package taletree

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestJSONEscaping(t *testing.T) {
	var sb strings.Builder
	writeJSONString(&sb, "a\"b\\c\nd\te\x01<script>&</script>\u2028é🍻")
	uassert.Equal(t, `"a\"b\\c\nd\te\u0001\u003cscript\u003e\u0026\u003c/script\u003e\u2028é🍻"`, sb.String())

	sb.Reset()
	writeJSONString(&sb, "bad\xffbyte")
	uassert.Equal(t, "\"bad\uFFFDbyte\"", sb.String())

	uassert.Equal(t, "short", excerpt("short", 10))
	uassert.Equal(t, "abc…", excerpt("abcdef", 3))
	uassert.Equal(t, "ab…", excerpt("abé", 3), "never cuts inside a rune")
}

func TestJSONReadAPI(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	StartTale(cross(cur), `Quotes "and" <tags>`, opening)
	testing.SetRealm(testing.NewUserRealm(bob))
	p2 := Branch(cross(cur), 1, "Go left", body)
	p3 := WriteEnding(cross(cur), p2, "Stop here", body)
	Branch(cross(cur), 1, "Go right", body)
	testing.SetRealm(testing.NewUserRealm(carol))
	Cheer(cross(cur), p2)

	stats := StatsJSON()
	uassert.True(t, strings.HasPrefix(stats, `{"tales":1,"passages":4,"bards":2,"tipsUgnot":0,"paused":false,"keeper":"`), stats)
	uassert.True(t, strings.Contains(stats, `"maxBody":1500}}`), stats)

	list := TalesJSON(1, 10)
	uassert.True(t, strings.HasPrefix(list, `{"total":1,"page":1,"size":10,"tales":[{"id":1,"title":"Quotes \"and\" \u003ctags\u003e"`), list)
	uassert.True(t, strings.Contains(list, `"excerpt":"The tavern fire`), list)
	uassert.Equal(t, `{"total":1,"page":2,"size":10,"tales":[]}`, TalesJSON(2, 10))

	tale := TaleJSON(1)
	uassert.True(t, strings.Contains(tale, `"canon":[1,2,3]`), tale)
	uassert.True(t, strings.Contains(tale, `"truncated":false}`), tale)
	uassert.Equal(t, 4, strings.Count(tale, `"parent":`)-1, "outline lists the 4 passages, plus the opening object")
	uassert.Equal(t, `{"error":"not_found"}`, TaleJSON(9))
	uassert.Equal(t, `{"error":"not_found"}`, TaleJSON(0))

	pj := PassageJSON(p3)
	uassert.True(t, strings.Contains(pj, `"path":[{"id":1,"choice":"","depth":0},{"id":2,"choice":"Go left","depth":1}]`), pj)
	uassert.True(t, strings.Contains(pj, `"ending":true`), pj)
	uassert.True(t, strings.Contains(pj, `"choices":[]`), pj)

	root := PassageJSON(1)
	uassert.True(t, strings.Contains(root, `"choice":"Go left"`), root)
	uassert.True(t, strings.Contains(root, `"choice":"Go right"`), root)

	canon := CanonJSON(1)
	uassert.Equal(t, 3, strings.Count(canon, `"body":`), canon)

	fame := FameJSON(5)
	uassert.True(t, strings.HasPrefix(fame, `{"total":2,"bards":[{"addr":"`+bob.String()+`"`), fame)
	uassert.True(t, strings.Contains(fame, `"cheers":1`), fame)

	bard := BardJSON(bob.String())
	uassert.True(t, strings.Contains(bard, `"passages":3,"tales":0`), bard)
	uassert.True(t, strings.Contains(bard, `"taleTitle":"Quotes`), bard)
	uassert.Equal(t, `{"error":"invalid_address"}`, BardJSON("nope"))
	uassert.True(t, strings.Contains(BardJSON(dave.String()), `"bard":null}`))

	// Hidden passages leave the JSON exactly as they leave the pages.
	testing.SetRealm(testing.NewUserRealm(alice))
	Hide(cross(cur), p2, "spoilers")
	hidden := PassageJSON(p3)
	uassert.True(t, strings.Contains(hidden, `"passage":{"id":3,"tale":1,"hidden":true}`), hidden)
	uassert.False(t, strings.Contains(hidden, body), "hidden body is not served")
	reason := PassageJSON(p2)
	uassert.True(t, strings.Contains(reason, `"reason":"spoilers"`), reason)
	uassert.False(t, strings.Contains(PassageJSON(1), `"Go left"`), "hidden choice is not listed")
	uassert.False(t, strings.Contains(TaleJSON(1), `"Go left"`), "hidden branch is not in the outline")
	uassert.False(t, strings.Contains(BardJSON(bob.String()), `"Stop here"`), "hidden passages leave the bard page")

	Hide(cross(cur), 1, "")
	ht := TaleJSON(1)
	uassert.True(t, strings.Contains(ht, `"title":""`), ht)
	uassert.False(t, strings.Contains(ht, `"opening"`), ht)
	uassert.False(t, strings.Contains(TalesJSON(1, 10), "Quotes"), "hidden tale title is not listed")
}
