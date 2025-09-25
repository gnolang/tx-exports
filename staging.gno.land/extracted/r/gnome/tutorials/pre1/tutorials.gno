package tutorials

import (
	"gno.land/p/gnome/blog"
)

var (
	locked               bool
	nextVersionRealmPath string

	tutorialsBlog = blog.Blog{Title: "Gno.me Tutorials"} // TODO: Define a realm description
)

func mustGetPost(slug string) *blog.Post {
	p, found := tutorialsBlog.GetPost(slug)
	if !found {
		panic("tutorial not found")
	}
	return p
}

func assertRealmIsNotLocked() {
	if locked {
		panic("realm is locked")
	}
}
