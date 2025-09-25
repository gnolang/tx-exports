package tutorials

import (
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/blog"
)

const keyDateFmt = "2006-01-02T15:04:05"

var (
	tags      tagIndex
	tutorials tutorialIndex
)

type tagIndex struct {
	index avl.Tree // string(tag) -> *tutorialIndex
}

func (x *tagIndex) Index(p *blog.Post) (indexed bool) {
	if p == nil {
		return
	}

	for _, tag := range p.Tags {
		// Get the tutorials for the current tag
		var (
			idx      *tutorialIndex
			v, found = x.index.Get(tag)
		)

		if found {
			idx = v.(*tutorialIndex)
		} else {
			idx = &tutorialIndex{}
		}

		// Index the tutorial
		idx.Index(p)

		// Keep track of indexing success
		indexed = x.index.Set(tag, idx) || indexed
	}
	return
}

func (x *tagIndex) Remove(p *blog.Post) (removed bool) {
	if p == nil {
		return
	}

	for _, tag := range p.Tags {
		v, found := x.index.Get(tag)
		if !found {
			// Ignore tags that are not indexed
			continue
		}

		idx := v.(*tutorialIndex)
		if idx.Remove(p) && !removed {
			removed = true
		}

		if idx.Size() == 0 {
			// Remove the tag from the index when empty
			x.index.Remove(tag)
		}
	}
	return
}

func (x tagIndex) IterateTags(fn func(tag string) bool) bool {
	return x.index.Iterate("", "", func(tag string, _ interface{}) bool {
		return fn(tag)
	})
}

func (x tagIndex) IteratePosts(tag string, fn func(*blog.Post) bool) bool { // TODO: Support pagination
	v, found := x.index.Get(tag)
	if !found {
		return false
	}

	idx := v.(*tutorialIndex)
	return idx.Iterate("", "", func(p *blog.Post) bool {
		return fn(p)
	})
}

type tutorialIndex struct {
	index avl.Tree // string(post creation time + post slug) -> *blog.Post
}

func (x tutorialIndex) Size() int {
	return x.index.Size()
}

func (x *tutorialIndex) Index(p *blog.Post) bool {
	k := newTutorialKey(p)
	return x.index.Set(k, p)
}

func (x *tutorialIndex) Remove(p *blog.Post) bool {
	k := newTutorialKey(p)
	_, removed := x.index.Remove(k)
	return removed
}

func (x tutorialIndex) Iterate(start, end string, fn func(*blog.Post) bool) bool {
	return x.index.Iterate(start, end, func(_ string, v interface{}) bool {
		return fn(v.(*blog.Post))
	})
}

func newTutorialKey(p *blog.Post) string {
	if p != nil {
		return p.CreatedAt.UTC().Format(keyDateFmt) + p.Slug
	}

	// By default create a key for the current block time
	return time.Now().UTC().Format(keyDateFmt)
}
