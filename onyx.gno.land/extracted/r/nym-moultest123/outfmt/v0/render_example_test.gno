package outfmt

// ExampleRender pins the realm's Render output as a testable example.
func ExampleRender() {
	print(Render(""))
	// Output:
	// * [?fmt=stringer](/r/nym-moultest123/outfmt:?fmt=stringer)
	// * [?fmt=json](/r/nym-moultest123/outfmt:?fmt=json)
	// * [?fmt=jsonp](/r/nym-moultest123/outfmt:?fmt=jsonp)
}
