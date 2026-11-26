package hello2

import (
    "strconv"

    "gno.land/p/moul/txlink"
)

var count int

func Increment(cur realm) int {
    count++
    return count
}

func Render(path string) string {
    // Create a clickable link that calls Increment
    button := txlink.Call("Increment")

    return "# Hello World\n\n" +
        "Welcome to my first realm!\n\n" +
        "**Current count:** " + strconv.Itoa(count) + "\n\n" +
        "[Click here to increase the count](" + button + ")\n\n" +
        "The count goes up every time someone clicks the link and signs the transaction."
}
