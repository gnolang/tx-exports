package blog

import (
	"strings"

	"gno.land/p/demo/avl"
)

type (
	// Blog defines a blog.
	Blog struct {
		posts avl.Tree // string(slug) -> *Post

		// Title is blog's title.
		Title string

		// Description is the blog's description.
		Description string
	}

	// PostIterFn defines the a callback to iterate blog posts.
	PostIterFn func(*Post) bool
)

// HasPost checks if a post with a URL slug exists.
func (b Blog) HasPost(slug string) bool {
	return b.posts.Has(slug)
}

// GetPost returns a blog's post.
func (b Blog) GetPost(slug string) (_ *Post, found bool) {
	if v, found := b.posts.Get(slug); found {
		return v.(*Post), true
	}
	return nil, false
}

// AddPost adds a new post to the blog.
func (b *Blog) AddPost(p *Post) bool {
	slug := strings.TrimSpace(p.Slug)
	if slug == "" {
		panic("post has an empty slug")
	}

	return b.posts.Set(slug, p)
}

// RemovePost removes a post from the blog.
// The removed post is returned after being removed if it exists.
func (b *Blog) RemovePost(slug string) (_ *Post, removed bool) {
	if v, removed := b.posts.Remove(slug); removed {
		return v.(*Post), true
	}
	return nil, false
}

// IteratePosts iterates all posts by slug.
func (b Blog) IteratePosts(fn PostIterFn) bool {
	// TODO: Improve blog post iteration
	return b.posts.Iterate("", "", func(_ string, value interface{}) bool {
		return fn(value.(*Post))
	})
}
