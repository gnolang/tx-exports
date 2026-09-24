package main

import "gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/bloom/v0"

func main() {
	// Create a filter expecting up to 1000 items with a 1% false-positive rate.
	b := bloom.New(1000, 0.01)

	b.AddString("apple").AddString("banana")

	println("Has apple:", b.ContainsString("apple"))
	println("Has banana:", b.ContainsString("banana"))
	println("Has cherry:", b.ContainsString("cherry"))
}

// Output:
// Has apple: true
// Has banana: true
// Has cherry: false
