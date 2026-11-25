package grounds

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestEmptyBoard(t *testing.T) {
	uassert.Equal(t, 0, len(Board()))
	page := Render("")
	uassert.True(t, strings.Contains(page, "| [B01: the leaky ledger](/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b01) |"), page)
	uassert.True(t, strings.Contains(page, "Nobody has broken a ground yet."), page)
}
