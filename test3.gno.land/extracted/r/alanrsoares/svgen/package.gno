package svgen

import (
    "fmt"
    "math/rand"
)
// Render generates an HTML document containing a random number of SVG shapes randomly positioned.
func Render(path string) string {
    numShapes := rand.Intn(4) + 3 // Random number of shapes between 3 and 6.
    shapes := []string{}

    for i := 0; i < numShapes; i++ {
        switch rand.Intn(3) {
        case 0:
            shapes = append(shapes, circle())
        case 1:
            shapes = append(shapes, rectangle())
        case 2:
            shapes = append(shapes, triangle())
        }
    }

    // Join all SVG elements into a single SVG tag.
    svgContent := fmt.Sprintf(`<svg height="256" width="256">%s</svg>`, stringJoin(shapes, ""))

    // HTML content with embedded SVG
    html := fmt.Sprintf(`
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Random SVG Shapes</title>
        </head>
        <body>
            %s
        </body>
        </html>
    `, svgContent)

    fmt.Println(html)
}


// randomColor generates a random hex color code.
func randomColor() string {
    return fmt.Sprintf("#%06x", rand.Intn(16777215))
}

// circle returns an SVG element string representing a circle at a random position.
func circle() string {
    radius := rand.Intn(30) + 10 // Circle radius between 10 and 40.
    x := rand.Intn(256 - radius*2) + radius
    y := rand.Intn(256 - radius*2) + radius
    color := randomColor()
    return fmt.Sprintf(`<circle cx="%d" cy="%d" r="%d" stroke="black" stroke-width="3" fill="%s" />`, x, y, radius, color)
}

// rectangle returns an SVG element string representing a rectangle at a random position.
func rectangle() string {
    width := rand.Intn(60) + 10  // Rectangle width between 10 and 70.
    height := rand.Intn(60) + 10 // Rectangle height between 10 and 70.
    x := rand.Intn(256 - width)
    y := rand.Intn(256 - height)
    color := randomColor()
    return fmt.Sprintf(`<rect x="%d" y="%d" width="%d" height="%d" stroke="black" stroke-width="3" fill="%s" />`, x, y, width, height, color)
}

// triangle returns an SVG element string representing a triangle at a random position.
func triangle() string {
    x1 := rand.Intn(256)
    y1 := rand.Intn(256)
    x2 := x1 + rand.Intn(60) - 30
    y2 := y1 + rand.Intn(60) - 30
    x3 := x1 + rand.Intn(60) - 30
    y3 := y1 + rand.Intn(60) - 30
    color := randomColor()
    return fmt.Sprintf(`<polygon points="%d,%d %d,%d %d,%d" stroke="black" stroke-width="3" fill="%s" />`, x1, y1, x2, y2, x3, y3, color)
}

// stringJoin concatenates slice elements with a separator.
func stringJoin(items []string, sep string) string {
    switch len(items) {
    case 0:
        return ""
    case 1:
        return items[0]
    }
    n := len(sep) * (len(items) - 1)
    for i := 0; i < len(items); i++ {
        n += len(items[i])
    }
    b := make([]byte, n)
    bp := copy(b, items[0])
    for _, s := range items[1:] {
        bp += copy(b[bp:], sep)
        bp += copy(b[bp:], s)
    }
    return string(b)
}
