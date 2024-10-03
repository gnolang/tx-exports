package space

// TODO: Remove this file if Gno implements invar (inmutable) references

import "time"

func newInvarTool(t *Tool) InvarTool {
	return InvarTool{t}
}

type InvarTool struct {
	ref *Tool
}

func (t InvarTool) Name() string {
	return t.ref.Name
}

func (t InvarTool) Description() string {
	return t.ref.Description
}

func (t InvarTool) URL() string {
	return t.ref.URL
}

func (t InvarTool) Icon() string {
	return t.ref.Icon
}

func newInvarLink(l *Link) InvarLink {
	return InvarLink{l}
}

type InvarLink struct {
	ref *Link
}

func (l InvarLink) URL() string {
	return l.ref.URL
}

func (l InvarLink) Title() string {
	return l.ref.Title
}

func newInvarNews(n *News) InvarNews {
	return InvarNews{n}
}

type InvarNews struct {
	ref *News
}

func (n InvarNews) ID() ID {
	return n.ref.ID
}

func (n InvarNews) Title() string {
	return n.ref.Title
}

func (n InvarNews) URL() string {
	return n.ref.URL
}

func (n InvarNews) ImageURL() string {
	return n.ref.ImageURL
}

func (n InvarNews) Tags() []string {
	return append([]string(nil), n.ref.Tags...)
}

func (n InvarNews) CreatedAt() time.Time {
	return n.ref.CreatedAt
}

func newInvarDataSection(s *DataSection) InvarDataSection {
	return InvarDataSection{s}
}

type InvarDataSection struct {
	ref *DataSection
}

func (l InvarDataSection) Slug() string {
	return l.ref.Slug
}

func (l InvarDataSection) Title() string {
	return l.ref.Title
}

func (l InvarDataSection) Realm() string {
	return l.ref.Realm
}

func (l InvarDataSection) Datasource() Datasource {
	return l.ref.Datasource
}

func (l InvarDataSection) Disabled() bool {
	return l.ref.Disabled
}
