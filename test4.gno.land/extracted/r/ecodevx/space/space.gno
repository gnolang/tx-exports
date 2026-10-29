package space

import (
	"regexp"
	"std"
	"strings"

	"gno.land/p/demo/avl"
	"gno.land/p/ecodevx/mirror"
)

const gnomeNS = "gno.land/r/gnome/"

// TODO: slugs and mirrored could be improved
var (
	defaultRealm string
	reSlug       = regexp.MustCompile("^[a-z]+[a-z0-9-]*$")
	slugs        = avl.NewTree() // string(slug) -> string(canonical realm path)
	mirrored     = avl.NewTree() // string(canonical realm path) -> string(realm path)
	realms       = mirror.New()
)

// Mirror registers the caller Gno.me realm to be mirrored.
//
// Caller realm must be a realm defined inside the `gnome` namespace.
// It's assumed that caller uses URL path suffix versioning.
//
// Parameters:
// - slug: A slug to use for rendering caller realm paths.
// - fn: A function to render caller realm paths.
func Mirror(slug string, fn mirror.RenderFn) {
	if fn == nil {
		panic("render function is required")
	}

	assertCallerIsGnomeRealm()
	assertIsSlug(slug)

	path := std.PrevRealm().PkgPath()
	canonical := getCanonicalPath(path)
	realms.Register(canonical, fn)

	slugs.Set(slug, canonical)
	mirrored.Set(canonical, path)
}

// MirroredPath returns the path of a mirrored realm.
//
// Parameters:
// - realm: Canonical realm path.
func MirroredPath(realm string) string {
	v, found := mirrored.Get(realm)
	if !found {
		panic("realm not found")
	}
	return v.(string)
}

// MakeDefault assigns the caller Gno.me realm as the default realm.
// Caller realm must be registered before making it the default one.
// Default realm is called when the render path is empty.
func MakeDefault() {
	assertCallerIsGnomeRealm()

	path := std.PrevRealm().PkgPath()
	canonical := getCanonicalPath(path)
	if !mirrored.Has(canonical) {
		panic("caller realm is not mirrored: " + path)
	}

	defaultRealm = canonical
}

// Render returns a Markdown string with the ouput of a mirrored Gno.me realm.
func Render(path string) string {
	if path == "" {
		if defaultRealm != "" {
			return realms.MustRender(defaultRealm, "")
		}
		return "Path not found"
	}

	slug, suffixPath, _ := strings.Cut(path, "/")
	v, found := slugs.Get(slug)
	if !found {
		panic("Not found")
	}

	canonical := v.(string)
	return realms.MustRender(canonical, suffixPath)
}

// getCanonicalPath removes version suffix from a realm path.
func getCanonicalPath(path string) string {
	return path[:strings.LastIndex(path, "/")]
}

func assertCallerIsGnomeRealm() {
	if !strings.HasPrefix(std.PrevRealm().PkgPath(), gnomeNS) {
		panic("caller must be a gnome realm")
	}
}

func assertIsSlug(s string) {
	if !reSlug.MatchString(s) {
		panic("invalid slug")
	}
}
