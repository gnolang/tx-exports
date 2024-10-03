package tutorials

import (
	"errors"
	"time"

	"gno.land/p/ecodevx/blog"
	space "gno.land/r/ecodevx/space/pre1"
)

var _ space.Datasource = (*datasource)(nil)

func NewDatasource() space.Datasource {
	return &datasource{}
}

type datasource struct{}

func (ds datasource) Iterate(start string, fn space.RecordIterFn) bool {
	return tutorials.ReverseIterate(start, "", func(key string, p *blog.Post) bool {
		if isTutorialPublished(p) {
			return fn(key, &postRecord{p})
		}
		return false
	})
}

func (ds datasource) IterateByTag(tag, start string, fn space.RecordIterFn) bool {
	return tags.ReverseIteratePosts(tag, start, func(key string, p *blog.Post) bool {
		if isTutorialPublished(p) {
			return fn(key, &postRecord{p})
		}
		return false
	})
}

func (ds datasource) GetContent(slug string, fn func(content string)) error {
	p, found := tutorials.Get(slug)
	if !found {
		return errors.New("tutorial not found")
	}

	if !isTutorialPublished(p) {
		return errors.New("tutorial is not published")
	}

	fn(p.Content)
	return nil
}

var _ space.Record = (*postRecord)(nil)

type postRecord struct {
	post *blog.Post
}

func (r postRecord) GetSlug() string            { return r.post.Slug }
func (r postRecord) GetTitle() string           { return r.post.Title }
func (r postRecord) GetImage() string           { return "" } // TODO: What image should be returned?
func (r postRecord) GetDescription() string     { return r.post.Summary }
func (r postRecord) GetTags() []string          { return r.post.Tags }
func (r postRecord) GetCreationTime() time.Time { return r.post.CreatedAt }
