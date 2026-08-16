package grc721v2

import (
	"chain"
	"encoding/base64"
	"strings"

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

// TokenURI composes a standard OpenSea-shaped data: URI directly from
// this token's on-chain metadata (SetTokenMetadata/TokenMetadata) —
// deliberately NOT BasicNFT.TokenURI/SetTokenURI, which is a completely
// separate, unrelated store nothing here ever populates. A previous
// version of this method delegated there by mistake, so TokenURI always
// failed with ErrInvalidTokenId for every metadata-bearing token, even
// though TokenMetadata itself worked fine — the real marketplace-facing
// getter was silently broken while the data underneath it was correct.
func (s *MetadataNFT) TokenURI(tid TokenID) (string, error) {
	metadata, err := s.TokenMetadata(tid)
	if err != nil {
		return "", err
	}
	return metadataDataURI(metadata), nil
}

// jsonEscape escapes the handful of characters that would otherwise
// break a JSON string literal. Gno's stdlib has no encoding/json, so
// every on-chain metadata JSON string in this package is hand-built.
func jsonEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// metadataDataURI renders m as a data:application/json;base64,... URI —
// the standard shape a marketplace's TokenURI() call expects: fetch it,
// base64-decode, parse as JSON, render the "image" field. ImageData is
// used only as a fallback when Image is empty (matches the field's own
// doc comment: "Only used if Image is empty").
func metadataDataURI(m Metadata) string {
	image := m.Image
	if image == "" {
		image = m.ImageData
	}

	var b strings.Builder
	b.WriteString(`{"name":"`)
	b.WriteString(jsonEscape(m.Name))
	b.WriteString(`","description":"`)
	b.WriteString(jsonEscape(m.Description))
	b.WriteString(`","image":"`)
	b.WriteString(jsonEscape(image))
	b.WriteString(`"`)
	if m.ExternalURL != "" {
		b.WriteString(`,"external_url":"`)
		b.WriteString(jsonEscape(m.ExternalURL))
		b.WriteString(`"`)
	}
	if m.BackgroundColor != "" {
		b.WriteString(`,"background_color":"`)
		b.WriteString(jsonEscape(m.BackgroundColor))
		b.WriteString(`"`)
	}
	if m.AnimationURL != "" {
		b.WriteString(`,"animation_url":"`)
		b.WriteString(jsonEscape(m.AnimationURL))
		b.WriteString(`"`)
	}
	if m.YoutubeURL != "" {
		b.WriteString(`,"youtube_url":"`)
		b.WriteString(jsonEscape(m.YoutubeURL))
		b.WriteString(`"`)
	}
	b.WriteString(`,"attributes":[`)
	for i, t := range m.Attributes {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"trait_type":"`)
		b.WriteString(jsonEscape(t.TraitType))
		b.WriteString(`","value":"`)
		b.WriteString(jsonEscape(t.Value))
		b.WriteString(`"}`)
	}
	b.WriteString("]}")

	return "data:application/json;base64," + base64.StdEncoding.EncodeToString([]byte(b.String()))
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

// Burn destroys tid, freeing its on-chain metadata storage as well as
// BasicNFT's own owners/tokenApprovals entries. v1 (gno.land/p/.../grc721)
// only freed the latter -- a handful of bytes -- and left this struct's
// own extensions entry (the actual image/name/attributes, routinely
// 10-20KB for an on-chain-art collection) permanently orphaned in state,
// so burning never actually recovered the storage deposit that dominated
// a mint's real cost. BasicNFT.Burn runs first since it's what validates
// tid is a real, currently-owned token (via OwnerOf) -- only remove
// extensions once that's confirmed to succeed, so a burn attempt on an
// invalid/already-burned tid errors out cleanly instead of silently
// erasing metadata for a token that was never actually burned.
// extensions.Remove on a tid with no entry (a migrated-in token, which
// never gets one) is just a no-op, not an error.
func (s *MetadataNFT) Burn(tid TokenID) error {
	if err := s.BasicNFT.Burn(tid); err != nil {
		return err
	}
	s.extensions.Remove(tid.String())
	return nil
}

func (s *MetadataNFT) RenderHome() string {
	return s.BasicNFT.RenderHome()
}
