package standings

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestLadderKeyOrder(t *testing.T) {
	uassert.True(t, ladderKey(1016, bob) < ladderKey(1000, alice), "higher rating first")
	uassert.Equal(t, alice < bob, ladderKey(1000, alice) < ladderKey(1000, bob), "address order within a rating")
	uassert.Equal(t, 42, len(ladderKey(0, alice)))
}
