package blog

// TODO: Remove this file if Gno implements invar (inmutable) references

import "time"

func NewInvarBlog(b *Blog) InvarBlog {
	return InvarBlog{b}
}

type InvarBlog struct {
	ref *Blog
}

func (b InvarBlog) Title() string {
	return b.ref.Title
}

func (b InvarBlog) Description() string {
	return b.ref.Description
}

func (b InvarBlog) IteratePosts(fn func(InvarPost) bool) bool {
	return b.ref.IteratePosts(func(p *Post) bool {
		return fn(NewInvarPost(p))
	})
}

func NewInvarPost(p *Post) InvarPost {
	return InvarPost{p}
}

type InvarPost struct {
	ref *Post
}

func (p InvarPost) Slug() string {
	return p.ref.Slug
}

func (p InvarPost) Title() string {
	return p.ref.Title
}

func (p InvarPost) Summary() string {
	return p.ref.Summary
}

func (p InvarPost) Status() PostStatus {
	return p.ref.Status
}

func (p InvarPost) Content() string {
	return p.ref.Content
}

func (p InvarPost) ContentHash() string {
	return p.ref.ContentHash
}

func (p InvarPost) Authors() AddressList {
	return p.ref.Authors
}

func (p InvarPost) Editors() AddressList {
	return p.ref.Editors
}

func (p InvarPost) Contributors() AddressList {
	return p.ref.Contributors
}

func (p InvarPost) Publishers() AddressList {
	return p.ref.Publishers
}

func (p InvarPost) Tags() []string {
	return p.ref.Tags
}

func (p InvarPost) CreatedAt() time.Time {
	return p.ref.CreatedAt
}

func (p InvarPost) UpdatedAt() time.Time {
	return p.ref.UpdatedAt
}

func (p InvarPost) PublishAt() time.Time {
	return p.ref.PublishAt
}

func (p InvarPost) ExpireAt() time.Time {
	return p.ref.ExpireAt
}
