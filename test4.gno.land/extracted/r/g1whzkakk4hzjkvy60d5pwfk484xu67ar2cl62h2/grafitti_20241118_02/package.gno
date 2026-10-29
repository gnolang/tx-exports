package grafitti_20241118_02

import "gno.land/p/demo/ufmt"
import "strings"
import "std"

type Grafitti struct {
	Author  std.Address
	Content string
}
var wall []Grafitti

// Scribble some grafitti.
func CreateGrafitti(content string) {
	newGrafitti := Grafitti{
		Author:  std.GetOrigCaller(),
		Content: content,
	}
	wall = append(wall, newGrafitti)
}

func Render(path string) string {
	var output strings.Builder
	for _, grafitti := range wall {
		output.WriteString(ufmt.Sprintf("* %s: %s\n", grafitti.Author, grafitti.Content))
	}
	return output.String()
}