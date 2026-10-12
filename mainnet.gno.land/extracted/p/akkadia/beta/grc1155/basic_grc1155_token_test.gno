package grc1155

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestBasicGRC1155GetterReturnsReader(cur realm, t *testing.T) {
	token := NewBasicGRC1155Token("ipfs://metadata")
	reader := token.Getter()()

	uassert.Equal(t, "ipfs://metadata", reader.Uri())
	balance, err := reader.BalanceOf(testutils.TestAddress("readerOwner"), TokenID("1"))
	uassert.True(t, err == nil, "reader balance lookup should not error")
	uassert.Equal(t, int64(0), balance)
	uassert.False(t, reader.IsApprovedForAll(testutils.TestAddress("readerOwner"), testutils.TestAddress("readerOperator")), "reader should expose approval reads")
}
