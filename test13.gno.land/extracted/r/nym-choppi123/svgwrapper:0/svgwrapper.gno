package svgwrapper

import (
    "gno.land/p/demo/svg"
)

func CreateLogo() string {
    canvas := svg.NewCanvas(100, 100)
    canvas.Append(
        svg.NewCircle(50, 50, 40, "blue"),
        svg.NewText(30, 55, "Gno", "white"),
    )
    return canvas.String()
}

func CreateBadge(name string, color string) string {
    canvas := svg.NewCanvas(200, 60)
    canvas.Append(
        svg.NewRectangle(10, 10, 180, 40, color),
        svg.NewText(80, 35, name, "white"),
    )
    return canvas.String()
}
