package svgen

import (
	"math/rand"
)


// Renders a random svg image
func Render(path string) string {
	count := rand.Intn(4) + 3 // Random number of shapes between 3 and 6.

	shapes := []string{}
	for i := 0; i < count; i++ {
		switch rand.Intn(3) {
		case 0:
			shapes = append(shapes, circle())
		case 1:
			shapes = append(shapes, rectangle())
		case 2:
			shapes = append(shapes, triangle())
		}
	}

	svgContent := sprintf(`<svg height="256" width="256">%s</svg>`, concatSVGElements(shapes, ""))

	html := sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Random SVG Shapes</title>
</head>
<body>
    %s
</body>
</html>`, svgContent)

	return html
}

func concatSVGElements(items []string, sep string) string {
	if len(items) == 0 {
		return ""
	}
	var result string
	for _, item := range items {
		result += item + sep
	}
	return result
}

// itoa converts an integer to a string.
func itoa(num int) string {
	if num == 0 {
		return "0"
	}

	negative := num < 0
	if negative {
		num = -num
	}

	digits := []byte{}
	for num > 0 {
		digit := num % 10
		digits = append(digits, '0'+byte(digit))
		num /= 10
	}

	if negative {
		digits = append(digits, '-')
	}

	// Reverse the digits
	for i, j := 0, len(digits)-1; i < j; i, j = i+1, j-1 {
		digits[i], digits[j] = digits[j], digits[i]
	}

	return string(digits)
}

// sprintf formats a string with placeholders for strings (%s) and integers (%d).
func sprintf(format string, args ...interface{}) string {
	var result []byte
	argIndex := 0

	for i := 0; i < len(format); i++ {
		if format[i] == '%' && i+1 < len(format) {
			switch format[i+1] {
			case 'd':
				if argIndex < len(args) {
					if num, ok := args[argIndex].(int); ok {
						result = append(result, itoa(num)...)
					}
				}
				argIndex++
				i++
			case 's':
				if argIndex < len(args) {
					if str, ok := args[argIndex].(string); ok {
						result = append(result, str...)
					}
				}
				argIndex++
				i++
			default:
				result = append(result, format[i])
			}
		} else {
			result = append(result, format[i])
		}
	}
	return string(result)
}

// randomColor generates a random hex color code.
func randomColor() string {
	return "#" + itoa(rand.Intn(16777215))
}

func circle() string {
	radius := rand.Intn(30) + 10
	x := rand.Intn(256-radius*2) + radius
	y := rand.Intn(256-radius*2) + radius
	color := randomColor()
	return sprintf(`<circle cx="%d" cy="%d" r="%d" stroke="black" stroke-width="3" fill="%s" />`, x, y, radius, color)
}

func rectangle() string {
	width := rand.Intn(60) + 10
	height := rand.Intn(60) + 10
	x := rand.Intn(256 - width)
	y := rand.Intn(256 - height)
	color := randomColor()
	return sprintf(`<rect x="%d" y="%d" width="%d" height="%d" stroke="black" stroke-width="3" fill="%s" />`, x, y, width, height, color)
}

func triangle() string {
	x1 := rand.Intn(256)
	y1 := rand.Intn(256)
	x2 := x1 + rand.Intn(60) - 30
	y2 := y1 + rand.Intn(60) - 30
	x3 := x1 + rand.Intn(60) - 30
	y3 := y1 + rand.Intn(60) - 30
	color := randomColor()

	return sprintf(`<polygon points="%d,%d %d,%d %d,%d" stroke="black" stroke-width="3" fill="%s" />`, x1, y1, x2, y2, x3, y3, color)
}
