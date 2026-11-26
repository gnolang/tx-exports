package cube3x3

import "gno.land/p/nt/svg/v0"

// RenderCubeNetMarkdown returns a Markdown image of the cube net.
func RenderCubeNetMarkdown(c Cube, alt string) string {
	return cubeNetCanvas(c).Render(alt)
}

// RenderCubeNetDataURI returns the base64 SVG data URI of the cube net.
func RenderCubeNetDataURI(c Cube) string {
	return "data:image/svg+xml;base64," + cubeNetCanvas(c).Base64()
}

func cubeNetCanvas(c Cube) *svg.Canvas {
	const stickerSize = 12
	const faceSize = 3 * stickerSize
	const width, height = 4 * faceSize, 3 * faceSize
	canvas := svg.NewCanvas(width, height).WithViewBox(0, 0, width, height)

	// Place U above F and D below it, with L F R B across the middle.
	facePositions := [6][2]int{{1, 0}, {2, 1}, {1, 1}, {1, 2}, {0, 1}, {3, 1}}
	colors := [6]string{"#f5f5f5", "#b91c1c", "#15803d", "#facc15", "#f97316", "#1d4ed8"}
	for i, color := range c {
		face := facePositions[i/9]
		sticker := i % 9
		x := face[0]*faceSize + sticker%3*stickerSize
		y := face[1]*faceSize + sticker/3*stickerSize
		fill := "#6b7280"
		if int(color) < len(colors) {
			fill = colors[color]
		}
		canvas.Append(svg.NewRectangle(x, y, stickerSize-1, stickerSize-1, fill))
	}
	return canvas
}
