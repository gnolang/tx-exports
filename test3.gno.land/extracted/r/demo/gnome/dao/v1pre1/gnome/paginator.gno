package gnome

import (
	"math"
	"strconv"
	"strings"

	"gno.land/p/demo/ufmt"
)

const paginatorStyle = `<style>
.paginator { text-align: center; }
.paginator a { text-decoration: none; }
.paginator a:hover { text-decoration: underline; }
.paginator .left { padding-right: 4px; }
.paginator .right { padding-left: 4px; }
</style>`

var (
	defaultPageSize = 50
	minPageSize     = 1
	pagePrefix      = "page="
)

type (
	// PaginatorIterFn defines a callback to iterate page items.
	PaginatorIterFn func(index int) (stop bool)

	// PaginatorOption configures the paginator.
	PaginatorOption func(*Paginator)
)

// WithPageSize assigns a page size to a paginator.
// The minimum page size is 5.
func WithPageSize(size int) PaginatorOption {
	return func(p *Paginator) {
		if size < minPageSize {
			p.pageSize = minPageSize
		} else {
			p.pageSize = size
		}
	}
}

// WithItemCount assigns the total number of items that can be paginated.
// Assigning the total item count allows the paginator to determine the last page number.
func WithItemCount(count int) PaginatorOption {
	return func(p *Paginator) {
		p.itemCount = count
	}
}

// NewPaginator creates a new paginator.
// URI path must contain the page number for the paginator to iterate items.
// Page number is specified in the URI path using "page=N" where N is the page
// number which must start from 1. For example: gno.land/p/gnome:a/b/page=2.
// Paginator is disabled when the URI path doesn't have a page specified or
// when the specified page is not valid.
func NewPaginator(uri string, options ...PaginatorOption) Paginator {
	realmURI, renderPath := SplitRealmURI(uri)
	p := Paginator{
		realmPath: CutRealmDomain(realmURI),
		pageSize:  defaultPageSize,
	}

	for _, apply := range options {
		apply(&p)
	}

	p.lastPage = int(math.Ceil(float64(p.itemCount) / float64(p.pageSize)))

	// Iterate path items until paginator arguments are found.
	// Path prefix and suffix are kept to be able to generate
	// page URLs keeping the render path format.
	items := strings.Split(renderPath, "/")
	for i, item := range items {
		if strings.HasPrefix(item, pagePrefix) {
			p.pathSuffix = items[i+1:]
			p.page, _ = strconv.Atoi(item[len(pagePrefix):])
			break
		}

		p.pathPrefix = append(p.pathPrefix, item)
	}
	return p
}

// Paginator allows paging items.
type Paginator struct {
	realmPath                           string
	pathPrefix, pathSuffix              []string
	pageSize, page, lastPage, itemCount int
}

// Offset returns the index for the first page item.
func (p Paginator) Offset() int {
	if !p.IsEnabled() {
		return 0
	}
	return (p.page - 1) * p.pageSize
}

// PageSize returns the size of each page.
func (p Paginator) PageSize() int {
	return p.pageSize
}

// Page returns the current page number.
// Zero is returned when the paginator is disabled.
func (p Paginator) Page() int {
	return p.page
}

// LastPage returns the number of the last page.
// Zero is returned when paginator is initialized without the total item count.
func (p Paginator) LastPage() int {
	return p.lastPage
}

// IsEnabled checks if paginator is enabled.
func (p Paginator) IsEnabled() bool {
	return p.page > 0
}

// IsLastPage checks if the current page is the last one.
func (p Paginator) IsLastPage() bool {
	return p.page == p.lastPage
}

// GetPageURI returns the URI for a page.
// An empty string is returned when page is < 1.
func (p Paginator) GetPageURI(page int) string {
	if !p.IsEnabled() {
		return ""
	}

	renderPath := append(p.pathPrefix, pagePrefix+strconv.Itoa(page))
	renderPath = append(renderPath, p.pathSuffix...)
	return p.realmPath + ":" + strings.Join(renderPath, "/")
}

// PrevPageURI returns the URI path to the previous page.
// An empty string is returned when current page is the first page.
func (p Paginator) PrevPageURI() string {
	if p.page == 1 || !p.IsEnabled() {
		return ""
	}
	return p.GetPageURI(p.page - 1)
}

// NextPageURI returns the URI path to the next page.
func (p Paginator) NextPageURI() string {
	if p.IsLastPage() {
		return ""
	}
	return p.GetPageURI(p.page + 1)
}

// Iterate allows iterating page items.
func (p Paginator) Iterate(fn PaginatorIterFn) bool {
	if !p.IsEnabled() {
		return true
	}

	start := p.Offset()
	for i := start; i < start+p.PageSize(); i++ {
		if fn(i) {
			return true
		}
	}
	return false
}

func (p Paginator) Render() string {
	if !p.IsEnabled() {
		return ""
	}

	var markdown string
	if s := p.PrevPageURI(); s != "" {
		markdown = ufmt.Sprintf(`<a href="%s" class="left">&lt;-</a>`, s)
	} else {
		markdown += `<span class="left">--</span>`
	}

	// TODO: Add display links to other page numbers?
	markdown += ufmt.Sprintf("page %d", p.page)

	if s := p.NextPageURI(); s != "" {
		markdown += ufmt.Sprintf(`<a href="%s" class="right">-&gt;</a>`, s)
	} else {
		markdown += `<span class="right">--</span>`
	}

	return paginatorStyle + `<p class="paginator">` + markdown + `</p>`
}
