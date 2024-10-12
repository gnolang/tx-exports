package tutorials

import (
	"gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/blog"
)

// TODO: Define a realm description
var tutorialsBlog = blog.Blog{Title: "Gno.me Tutorials"}

func mustGetPost(slug string) *blog.Post {
	p, found := tutorialsBlog.GetPost(slug)
	if !found {
		panic("tutorial not found")
	}
	return p
}
