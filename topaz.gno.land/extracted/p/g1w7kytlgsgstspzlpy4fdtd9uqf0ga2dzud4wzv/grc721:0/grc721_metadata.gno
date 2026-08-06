package grc721

import (
	"chain"

	"gno.land/p/g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv/avl"
)

// MetadataNFT represents an NFT with on-chain metadata extensions.
type MetadataNFT struct {
	*BasicNFT
	extensions *avl.Tree // AVL tree for storing metadata extensions
}

// Ensure that MetadataNFT implements the IGRC721MetadataOnchain interface.
var _ IGRC721MetadataOnchain = (*MetadataNFT)(nil)

// NewNFTWithMetadata creates a new basic NFT with metadata extensions.
func NewNFTWithMetadata(_ int, rlm realm, name, symbol string) *MetadataNFT {
	return &MetadataNFT{
		BasicNFT:   NewBasicNFT(0, rlm, name, symbol),
		extensions: avl.NewTree(),
	}
}

// SetTokenMetadata sets metadata for a given token ID. The token must exist and
// caller must equal its owner; the owning realm's wrapper derives caller —
// see basic_nft.gno's NewBasicNFT doc comment for how.
func (s *MetadataNFT) SetTokenMetadata(caller address, tid TokenID, metadata Metadata) error {
	// Check that the token exists and the caller is its owner.
	owner, err := s.OwnerOf(tid)
	if err != nil {
		return err
	}
	if caller != owner {
		return ErrCallerIsNotOwner
	}

	// Set the metadata for the token ID in the extensions AVL tree
	s.extensions.Set(tid.String(), metadata)

	chain.Emit(
		MetadataUpdateEvent,
		"token", s.ID(),
		"tokenId", tid.String(),
	)

	return nil
}

// TokenMetadata retrieves metadata for a given token ID.
func (s *MetadataNFT) TokenMetadata(tid TokenID) (Metadata, error) {
	// Retrieve metadata from the extensions AVL tree
	metadata := s.extensions.Get(tid.String())
	if metadata == nil {
		return Metadata{}, ErrInvalidTokenId
	}

	return metadata.(Metadata), nil
}

// Basic NFT methods forwarded to embedded BasicNFT

func (s *MetadataNFT) Name() string {
	return s.BasicNFT.Name()
}

func (s *MetadataNFT) Symbol() string {
	return s.BasicNFT.Symbol()
}

func (s *MetadataNFT) TokenCount() int64 {
	return s.BasicNFT.TokenCount()
}

func (s *MetadataNFT) BalanceOf(addr address) (int64, error) {
	return s.BasicNFT.BalanceOf(addr)
}

func (s *MetadataNFT) OwnerOf(tid TokenID) (address, error) {
	return s.BasicNFT.OwnerOf(tid)
}

func (s *MetadataNFT) TokenURI(tid TokenID) (string, error) {
	return s.BasicNFT.TokenURI(tid)
}

func (s *MetadataNFT) SetTokenURI(caller address, tid TokenID, tURI TokenURI) (bool, error) {
	return s.BasicNFT.SetTokenURI(caller, tid, tURI)
}

func (s *MetadataNFT) IsApprovedForAll(owner, operator address) bool {
	return s.BasicNFT.IsApprovedForAll(owner, operator)
}

func (s *MetadataNFT) Approve(caller, to address, tid TokenID) error {
	return s.BasicNFT.Approve(caller, to, tid)
}

func (s *MetadataNFT) GetApproved(tid TokenID) (address, error) {
	return s.BasicNFT.GetApproved(tid)
}

func (s *MetadataNFT) SetApprovalForAll(caller, operator address, approved bool) error {
	return s.BasicNFT.SetApprovalForAll(caller, operator, approved)
}

func (s *MetadataNFT) SafeTransferFrom(caller, from, to address, tid TokenID) error {
	return s.BasicNFT.SafeTransferFrom(caller, from, to, tid)
}

func (s *MetadataNFT) TransferFrom(caller, from, to address, tid TokenID) error {
	return s.BasicNFT.TransferFrom(caller, from, to, tid)
}

func (s *MetadataNFT) Mint(to address, tid TokenID) error {
	return s.BasicNFT.Mint(to, tid)
}

func (s *MetadataNFT) SafeMint(to address, tid TokenID) error {
	return s.BasicNFT.SafeMint(to, tid)
}

func (s *MetadataNFT) Burn(tid TokenID) error {
	return s.BasicNFT.Burn(tid)
}

func (s *MetadataNFT) RenderHome() string {
	return s.BasicNFT.RenderHome()
}
