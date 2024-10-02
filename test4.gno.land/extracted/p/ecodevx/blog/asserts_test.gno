package blog

import (
	"testing"

	"gno.land/p/ecodevx/blog"
)

func TestIsSlug(t *testing.T) {
	cases := []struct {
		name, slug string
		want       bool
	}{
		{
			name: "empty",
			want: false,
		},
		{
			name: "one letter",
			slug: "a",
			want: true,
		},
		{
			name: "one unicode letter",
			slug: "á",
			want: true,
		},
		{
			name: "one word",
			slug: "foo",
			want: true,
		},
		{
			name: "one unicode word",
			slug: "fóo",
			want: true,
		},
		{
			name: "many words",
			slug: "foo-bar-baz",
			want: true,
		},
		{
			name: "many unicode words",
			slug: "fóo-bár-báz",
			want: true,
		},
		{
			name: "with spaces",
			slug: "foo bar",
			want: false,
		},
		{
			name: "with invalid chars",
			slug: "foo/bar",
			want: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			got := blog.IsSlug(tc.slug)

			// Assert
			if got != tc.want {
				t.Fatalf("expected slug check to return: %v", tc.want)
			}
		})
	}
}

func TestIsSha256Hash(t *testing.T) {
	cases := []struct {
		name, hash string
		want       bool
	}{
		{
			name: "empty",
			want: false,
		},
		{
			name: "ok",
			hash: "1a66cf828aea323fc58c653b0bc0d64061bb5c198e500a541a2c97f4f45b668d",
			want: true,
		},
		{
			name: "invalid size",
			hash: "1a66cf828aea323",
			want: false,
		},
		{
			name: "invalid characters",
			hash: "1a66#?",
			want: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			got := blog.IsSha256Hash(tc.hash)

			// Assert
			if got != tc.want {
				t.Fatalf("expected sha256 check check to return: %v", tc.want)
			}
		})
	}
}

func TestIsURL(t *testing.T) {
	cases := []struct {
		url  string
		want bool
	}{
		{url: "https", want: false},
		{url: "https/a", want: false},
		{url: "https/a/b", want: false},
		{url: "https/a/b/", want: false},
		{url: "https:", want: false},
		{url: "https:www.test.com", want: false},
		{url: "https:www.test.com/", want: false},
		{url: "https:www.test.com/a", want: false},
		{url: "https:www.test.com/a/b", want: false},
		{url: "https:www.test.com/a/b/", want: false},
		{url: "https:www.test.com:42/a/b/", want: false},
		{url: "https:/", want: false},
		{url: "https:/a", want: false},
		{url: "https:/a/b", want: false},
		{url: "https:/a/b/", want: false},
		{url: "https:/www.test.com/a/b", want: false},
		{url: "https://", want: false},
		{url: "https://a", want: false},
		{url: "https://a/b", want: false},
		{url: "https://a/b/", want: false},
		{url: "https://www.test.com", want: false},
		{url: "https://www.test.com/", want: false},
		{url: "https://www.test.com/a", want: true},
		{url: "https://www.test.com/a/b", want: true},
		{url: "https://www.test.com/a/b/", want: true},
		{url: "https://www.test.com:42/a/b/", want: true},
		{url: "https://foo.bar.test.com", want: false},
		{url: "https://foo.bar.test.com/", want: false},
		{url: "https://foo.bar.test.com/a", want: true},
		{url: "https://foo.bar.test.com/a/b", want: true},
		{url: "https://foo.bar.test.com/a/b/", want: true},
		{url: "https://foo.bar.test.com/a/b", want: true},
		{url: "https://foo.bar.test.com:42/a/b", want: true},
	}

	for _, tc := range cases {
		t.Run(tc.url, func(t *testing.T) {
			// Act
			got := blog.IsURL(tc.url, true)

			// Assert
			if got != tc.want {
				t.Fatalf("expected URL check to return: %v", tc.want)
			}
		})
	}
}

func TestGetHexSha256Hash(t *testing.T) {
	cases := []struct {
		name, content, want string
	}{
		{
			name: "empty",
			want: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		{
			name:    "ok",
			content: "foo",
			want:    "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			got := blog.GetHexSha256Hash(tc.content)

			// Assert
			if got != tc.want {
				t.Fatalf("expected hash: '%s', got: '%s'", tc.want, got)
			}
		})
	}
}
