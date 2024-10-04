package space

import (
	"time"
)

type (
	Record interface {
		GetSlug() string
		GetTitle() string
		GetImage() string
		GetDescription() string
		GetTags() []string
		GetCreationTime() time.Time
	}

	RecordIterFn = func(key string, _ Record) bool

	Datasource interface {
		Iterate(start string, fn RecordIterFn) bool
		IterateByTag(tag, start string, fn RecordIterFn) bool
		GetContent(slug string, fn func(content string)) error
	}

	DataSection struct {
		Slug        string
		Title       string
		Realm       string
		Datasource  Datasource
		BlockHeight int64
		Disabled    bool
	}
)
