package pager

import (
	"strconv"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/uassert/v0"
)

func fill(n int) *avl.Tree {
	t := avl.NewTree()
	for i := 0; i < n; i++ {
		k := strconv.Itoa(1000 + i) // fixed width keeps order numeric
		t.Set(k, i)
	}
	return t
}

func TestClamp(t *testing.T) {
	o, l := Clamp(-5, 0)
	uassert.Equal(t, 0, o)
	uassert.Equal(t, DefaultLimit, l)
	_, l = Clamp(0, 100000)
	uassert.Equal(t, MaxLimit, l)
}

func TestOfForward(t *testing.T) {
	p := Of(fill(45), 20, 20, false)
	uassert.Equal(t, 20, len(p.Items))
	uassert.Equal(t, "1020", p.Items[0].Key)
	uassert.Equal(t, 45, p.Total)
	uassert.True(t, p.HasPrev)
	uassert.True(t, p.HasNext)
	uassert.Equal(t, 2, p.PageNumber())
}

func TestOfReverseLastPage(t *testing.T) {
	p := Of(fill(45), 40, 20, true)
	uassert.Equal(t, 5, len(p.Items))
	uassert.Equal(t, "1004", p.Items[0].Key)
	uassert.False(t, p.HasNext)
}

func TestOfNeverExceedsMax(t *testing.T) {
	p := Of(fill(300), 0, 5000, false)
	uassert.Equal(t, MaxLimit, len(p.Items))
}

func TestOfNilTree(t *testing.T) {
	p := Of(nil, 0, 10, false)
	uassert.Equal(t, 0, len(p.Items))
	uassert.Equal(t, "", p.Nav("x"))
}

func TestParse(t *testing.T) {
	o, l := Parse("posts?page=3&size=10")
	uassert.Equal(t, 20, o)
	uassert.Equal(t, 10, l)

	o, l = Parse("posts")
	uassert.Equal(t, 0, o)
	uassert.Equal(t, DefaultLimit, l)

	o, l = Parse("?page=-2&size=abc")
	uassert.Equal(t, 0, o)
	uassert.Equal(t, DefaultLimit, l)

	_, l = Parse("?size=999999")
	uassert.Equal(t, MaxLimit, l)
}

func TestBase(t *testing.T) {
	uassert.Equal(t, "posts", Base("posts?page=2"))
	uassert.Equal(t, "posts", Base("posts"))
}

func TestNav(t *testing.T) {
	p := Of(fill(45), 20, 20, false)
	nav := p.Nav("board")
	uassert.Equal(t, "\n[« prev](board?page=1&size=20) | page 2/3 | [next »](board?page=3&size=20)\n", nav)

	single := Of(fill(3), 0, 20, false)
	uassert.Equal(t, "", single.Nav("board"))
}
