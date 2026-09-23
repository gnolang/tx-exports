package avatar

import (
	"strconv"

	"gno.land/p/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft/v0"
	settlers "gno.land/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft"
)

const (
	// MinSize is the minimum size allowed for an avatar in pixels.
	MinSize = 32

	// MaxSize is the maximum size allowed for an avatar in pixels.
	MaxSize = 2048
)

// SVG returns the SVG document of the Settler of an address, or an empty text if it has none.
//
// The size is the width and height in pixels of the square image, from 32 to 2048 (multiples of 32 keep
// every art pixel as a whole number of screen pixels). A size of 0 or less leaves out the width and the
// height, so that the image scales to its container. If transparent is true, the image has no background.
func SVG(addr address, size int, transparent bool) string {
	if settlerID, traits := lookup(addr); settlerID != -1 {
		return nft.RenderSVG(traits, options(size, transparent))
	}
	return ""
}

// URI returns the image of the Settler of an address as a "data:image/svg+xml;charset=utf-8," URI, that can
// be used as the source of an image or as the address of a Markdown image, or an empty text if it has none.
// The size and transparent are the same as in SVG.
func URI(addr address, size int, transparent bool) string {
	if settlerID, traits := lookup(addr); settlerID != -1 {
		return nft.RenderDataURI(traits, options(size, transparent))
	}
	return ""
}

// Markdown returns the avatar of an address as a Markdown image, or an empty text if it has none:
//
//	![Settler #12](data:image/svg+xml;charset=utf-8,...)
//
// The size and transparent are the same as in SVG.
func Markdown(addr address, size int, transparent bool) string {
	if settlerID, traits := lookup(addr); settlerID != -1 {
		uri := nft.RenderDataURI(traits, options(size, transparent))
		return "![Settler #" + strconv.Itoa(settlerID) + "](" + uri + ")"
	}
	return ""
}

// lookup returns the ID and traits of the Settler of an address, or -1 and a zero-value Traits if it has none.
func lookup(addr address) (int, nft.Traits) {
	settlerID := settlers.TokenOf(addr)
	if settlerID == 0 {
		return -1, nft.Traits{}
	}

	traits := settlers.TraitsOf(settlerID)
	return settlerID, traits
}

// options builds the nft.Options for an image; size is clamped between MinSize and MaxSize (0 or less is
// left as 0, so the image has no fixed size and scales to its container), and transparent controls whether
// the background is drawn.
func options(size int, transparent bool) nft.Options {
	switch {
	case size <= 0:
		size = 0
	case size < MinSize:
		size = MinSize
	case size > MaxSize:
		size = MaxSize
	}

	return nft.Options{
		Size:         size,
		NoBackground: transparent,
	}
}
