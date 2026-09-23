package nft

import "testing"

func TestBuildGridPanicsWithInvalidTraits(t *testing.T) {
	for _, tc := range invalidTraits {
		t.Run(tc.name, func(t *testing.T) {
			// Act
			message := panicMessage(func() { BuildGrid(tc.traits) })

			// Assert
			assertContains(t, "panic", message, tc.err)
		})
	}
}
