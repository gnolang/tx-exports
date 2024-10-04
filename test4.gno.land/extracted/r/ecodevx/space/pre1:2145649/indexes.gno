package space

import (
	"gno.land/p/demo/avl"
)

var indexes struct {
	News        newsIndex
	Link        linkIndex
	DataSection dataSectionsIndex
}

type newsIndex struct {
	index avl.Tree // string(binary id) -> *News
	tags  avl.Tree // string(tag) -> []*News
}

func (x newsIndex) Size() int {
	return x.index.Size()
}

func (x *newsIndex) Index(n *News) {
	// Index by ID
	key := n.ID.Key()
	updated := x.index.Set(key, n)
	if updated {
		panic("news ID is already indexed: " + key)
	}

	// Index by tags
	for _, tag := range n.Tags {
		news := x.GetByTag(tag)
		x.tags.Set(tag, append(news, n))
	}
}

func (x newsIndex) GetByID(id ID) (*News, bool) {
	if v, ok := x.index.Get(id.Key()); ok {
		return v.(*News), true
	}
	return nil, false
}

func (x newsIndex) GetByTag(tag string) []*News {
	if v, ok := x.tags.Get(tag); ok {
		return v.([]*News)
	}
	return nil
}

func (x newsIndex) GetTags() (tags []string) {
	x.tags.Iterate("", "", func(tag string, _ interface{}) bool {
		tags = append(tags, tag)
		return false
	})
	return
}

func (x *newsIndex) Remove(id ID) bool {
	v, removed := x.index.Remove(id.Key())
	if !removed {
		return false
	}

	current := v.(*News)
	for _, tag := range current.Tags {
		news := x.GetByTag(tag)
		if len(news) == 0 {
			continue
		}

		for i, n := range news {
			if n.ID == current.ID {
				x.tags.Set(tag, append(news[:i], news[i+1:]...))
				break
			}
		}
	}
	return true
}

// Iterate iterates news starting from the oldest one.
func (x newsIndex) Iterate(fn func(*News) bool) bool {
	return x.index.Iterate("", "", func(_ string, v interface{}) bool {
		return fn(v.(*News))
	})
}

// ReverseIterate iterates news starting from the latest one.
func (x newsIndex) ReverseIterate(fn func(*News) bool) bool {
	return x.index.ReverseIterate("", "", func(_ string, v interface{}) bool {
		return fn(v.(*News))
	})
}

type linkIndex struct {
	index avl.Tree // string(section) -> []*Link
}

func (x *linkIndex) Index(s Section, l *Link) {
	links, _ := x.Get(s)
	links = append(links, l)
	x.index.Set(string(s), links)
}

func (x linkIndex) Get(s Section) ([]*Link, bool) {
	if v, ok := x.index.Get(string(s)); ok {
		return v.([]*Link), true
	}
	return nil, false
}

func (x linkIndex) Has(s Section) bool {
	return x.index.Has(string(s))
}

func (x *linkIndex) Remove(s Section, url string) bool {
	links, found := x.Get(s)
	if !found {
		return false
	}

	for i, l := range links {
		if l.URL != url {
			continue
		}

		return x.index.Set(string(s), append(links[:i], links[i+1:]...))
	}
	return false
}

// Iterate iterates links.
func (x linkIndex) Iterate(fn func(Section, *Link) bool) bool {
	return x.index.Iterate("", "", func(s string, v interface{}) bool {
		section := Section(s)
		for _, l := range v.([]*Link) {
			if fn(section, l) {
				return true
			}
		}
		return false
	})
}

type dataSectionsIndex struct {
	index   avl.Tree // string(slug) -> *DataSection
	ordered []*DataSection
}

func (x dataSectionsIndex) Size() int {
	return x.index.Size()
}

func (x *dataSectionsIndex) Index(s *DataSection) {
	// Index by slug
	x.index.Set(s.Slug, s)

	// Index by order
	x.ordered = append(x.ordered, s)
}

func (x dataSectionsIndex) GetBySlug(slug string) (*DataSection, bool) {
	if v, ok := x.index.Get(slug); ok {
		return v.(*DataSection), true
	}
	return nil, false
}

func (x *dataSectionsIndex) Remove(slug string) bool {
	_, removed := x.index.Remove(slug)
	if !removed {
		return false
	}

	for i, s := range x.ordered {
		if s.Slug == slug {
			x.ordered = append(x.ordered[:i], x.ordered[i+1:]...)
		}
	}
	return true
}

func (x *dataSectionsIndex) Reorder(currentOrder, newOrder int) bool {
	c := len(x.ordered)
	if currentOrder >= c || newOrder >= c {
		return false
	}

	s := x.ordered[currentOrder]
	x.ordered = append(x.ordered[:currentOrder], x.ordered[currentOrder+1:]...)
	x.ordered = append(x.ordered[:newOrder], append([]*DataSection{s}, x.ordered[newOrder:]...)...)
	return true
}

// Iterate iterates data sections.
func (x dataSectionsIndex) Iterate(fn func(*DataSection) bool) bool {
	for _, s := range x.ordered {
		if fn(s) {
			return true
		}
	}
	return false
}
