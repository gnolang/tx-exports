package flag

import "testing"

func TestDifficultyString(t *testing.T) {
	cases := map[Difficulty]string{Easy: "Easy", Medium: "Medium", Hard: "Hard", 0: "Unknown", 9: "Unknown"}
	for d, want := range cases {
		if got := d.String(); got != want {
			t.Errorf("Difficulty(%d).String() = %q, want %q", int(d), got, want)
		}
	}
}

func TestInfoValidate(t *testing.T) {
	good := Info{Slug: "open-rack", Title: "The Open Rack", Difficulty: Medium, Brief: "A rack."}
	if err := good.Validate(); err != nil {
		t.Fatalf("valid info rejected: %v", err)
	}
	cases := []struct {
		name string
		edit func(*Info)
		want error
	}{
		{"short slug", func(i *Info) { i.Slug = "ab" }, ErrBadSlug},
		{"upper slug", func(i *Info) { i.Slug = "Rack" }, ErrBadSlug},
		{"dash edge", func(i *Info) { i.Slug = "-rack" }, ErrBadSlug},
		{"no title", func(i *Info) { i.Title = "  " }, ErrNoTitle},
		{"bad grade", func(i *Info) { i.Difficulty = 7 }, ErrBadDifficulty},
		{"no brief", func(i *Info) { i.Brief = "" }, ErrNoBrief},
	}
	for _, tc := range cases {
		info := good
		tc.edit(&info)
		if err := info.Validate(); err != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, err, tc.want)
		}
	}
}
