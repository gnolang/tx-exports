package grc721v2

type IGRC721Reader interface {
	Name() string
	Symbol() string
	TokenCount() int64
	BalanceOf(owner address) (int64, error)
	OwnerOf(tid TokenID) (address, error)
	GetApproved(tid TokenID) (address, error)
	IsApprovedForAll(owner, operator address) bool
}

type (
	TokenID  string
	TokenURI string
)

func (t TokenID) String() string  { return string(t) }
func (t TokenURI) String() string { return string(t) }

const (
	MintEvent           = "Mint"
	BurnEvent           = "Burn"
	TransferEvent       = "Transfer"
	ApprovalEvent       = "Approval"
	ApprovalForAllEvent = "ApprovalForAll"
	TokenURIUpdateEvent = "TokenUriUpdate"
	MetadataUpdateEvent = "MetadataUpdate"
)

type NFTGetter func() IGRC721Reader
