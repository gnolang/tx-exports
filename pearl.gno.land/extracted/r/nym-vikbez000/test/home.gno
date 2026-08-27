package test

import "gno.land/p/moul/md"

func Render(path string) string {
	out := md.Strikethrough("test strikethrough")
	out += md.Blockquote("test blockquote")
	return out
}
