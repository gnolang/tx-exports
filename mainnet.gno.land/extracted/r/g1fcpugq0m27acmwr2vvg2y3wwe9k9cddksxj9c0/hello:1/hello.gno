package hello

import "strconv"

var count int

func Increment(cur realm) int {
    count++
    return count
}

func Render(path string) string {
    return "# Hello World\n\n" +
        "Welcome to my first realm!\n\n" +
        "**Current count:** " + strconv.Itoa(count) + "\n\n" +
        "[Click here to increase the count](https://gno.land/r/g1fcpugq0m27acmwr2vvg2y3wwe9k9cddksxj9c0/hello)\n\n" +
        "(After you deploy, the button will work properly)"
}
