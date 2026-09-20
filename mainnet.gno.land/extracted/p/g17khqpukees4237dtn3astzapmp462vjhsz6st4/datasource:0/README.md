# Datasource Package

Package defines generic interfaces for datasources. A datasource is a set of
records that can be read one at a time or iterated, and that can optionally be
taggable so they can be filtered by category.

Datasources are useful when the data exchanged between different realms has to
stay generic, avoiding direct dependencies between them. A realm that consumes
records only needs to know the `Datasource` interface, not the realm that
provides them.

The package doesn't ship a datasource implementation. It provides the contracts, a
`Query` type configured with the `WithOffset`, `WithCount`, `ByTag` and `WithFilter`
options, and the `NewIterator` and `QueryRecords` helpers. How each query option
is honoured is up to the datasource. `QueryRecords` enforces the record count
itself, so datasources only have to apply the tag, filters and offset.

Datasources that keep their records in memory can use `NewRecordIterator` to
return the iterator that queries expect, and `NewFieldsFromMap` to expose a map
as read-only record fields, instead of writing their own.

> [!WARNING]
> For security, any public function that accepts a Datasource as a parameter from
> external callers MUST verify that the received datasource is an expected canonical
> one.

Repository can be found at [jeronimoalbi/gnome](https://github.com/jeronimoalbi/gnome),
as part of `jeronimoalbi`'s Gno smart contracts monorepo.

## Usage

[embedmd]:# (filetests/readme_filetest.gno go)
```go
package main

import (
	"errors"
	"strings"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/datasource"
)

func main() {
	var ds datasource.Datasource = posts{
		{"1", "Hello Gno", []string{"gno"}},
		{"2", "Realms 101", []string{"gno", "realms"}},
		{"3", "Cooking pasta", []string{"food"}},
		{"4", "Testing in Gno", []string{"gno", "testing"}},
	}

	// Get the first two records tagged with "gno"
	records, err := datasource.QueryRecords(
		ds,
		datasource.ByTag("gno"),
		datasource.WithCount(2),
	)
	if err != nil {
		panic(err)
	}

	for _, r := range records {
		println(r.ID(), r.String())
	}

	// Get the next page of records tagged with "gno"
	records, err = datasource.QueryRecords(
		ds,
		datasource.ByTag("gno"),
		datasource.WithOffset(2),
		datasource.WithCount(2),
	)
	if err != nil {
		panic(err)
	}

	for _, r := range records {
		println(r.ID(), r.String())
	}

	// Get a single record, and use its optional interfaces
	r, err := ds.Record("2")
	if err != nil {
		panic(err)
	}

	if t, ok := r.(datasource.TaggableRecord); ok {
		println("Tags:", strings.Join(t.Tags(), ", "))
	}

	fields, err := r.Fields()
	if err != nil {
		panic(err)
	}

	title, _ := fields.Get("title")
	println("Title:", title.(string))
}

// Datasource: A list of posts
type posts []post

func (ps posts) Size() int { return len(ps) }

func (ps posts) Record(id string) (datasource.Record, error) {
	for _, p := range ps {
		if p.id == id {
			return p, nil
		}
	}
	return nil, errors.New("record not found")
}

func (ps posts) Records(q datasource.Query) datasource.Iterator {
	var records []datasource.Record
	for _, p := range ps {
		if q.Tag == "" || p.hasTag(q.Tag) {
			records = append(records, p)
		}
	}

	if q.Offset >= len(records) {
		return datasource.NewRecordIterator(nil)
	}
	return datasource.NewRecordIterator(records[q.Offset:])
}

// TaggableRecord: A post
type post struct {
	id    string
	title string
	tags  []string
}

func (p post) ID() string     { return p.id }
func (p post) String() string { return p.title }
func (p post) Tags() []string { return p.tags }

func (p post) Fields() (datasource.Fields, error) {
	return datasource.NewFieldsFromMap(map[string]any{
		"title": p.title,
	}), nil
}

func (p post) hasTag(tag string) bool {
	for _, t := range p.tags {
		if t == tag {
			return true
		}
	}
	return false
}

// Output:
// 1 Hello Gno
// 2 Realms 101
// 4 Testing in Gno
// Tags: gno, realms
// Title: Realms 101
```
