package home

import (
	"strings"
)

const (
	minSize     = 1
	defaultSize = 20
	maxSize     = 50
)

func DrawSnake(size int) string {
	if size < minSize || size > maxSize {
		panic("invalid snake size")
	}
	var b strings.Builder
	b.WriteString("     🐍 Snake (try) 🐍\n")
	b.WriteString(strings.Repeat("=", 40) + "\n\n")

	// Snake head
	b.WriteString("  ○○○○\n")
	b.WriteString(" ◍◍◍◍◍  ~🐍 HEAD\n")
	b.WriteString("◒\n")

	// Draw smooth snake body
	for i := 0; i < size; i++ {
		b.WriteString(drawSmoothBodySegment(i))
	}

	// Snake tail
	b.WriteString(drawSnakeTail())

	return b.String()
}

// Smoother, snake-like body segment
func drawSmoothBodySegment(i int) string {
	// Create a wavy snake-like body
	if i%2 == 0 {
		return `    ~~~~ 
   ///// 
  ~~~~~~
 ///////
~~~~~~~
`
	}
	return `  ~~~~~~ 
 ///////
  ~~~~~~
   /////
    ~~~~
`
}

// Tail for the snake
func drawSnakeTail() string {
	return "    🐍 TAIL\n"
}
