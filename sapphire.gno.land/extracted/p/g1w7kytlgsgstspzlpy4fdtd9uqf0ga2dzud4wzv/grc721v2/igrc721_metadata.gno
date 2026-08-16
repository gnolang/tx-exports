package grc721v2

// IGRC721CollectionMetadata describes basic information about an NFT collection.
type IGRC721CollectionMetadata interface {
	Name() string   // Name returns the name of the collection.
	Symbol() string // Symbol returns the symbol of the collection.
}

// IGRC721Metadata follows the Ethereum standard
type IGRC721Metadata interface {
	IGRC721CollectionMetadata
	TokenURI(tid TokenID) (string, error) // TokenURI returns the URI of a specific token.
}

// IGRC721MetadataOnchain follows the OpenSea metadata standard
type IGRC721MetadataOnchain interface {
	IGRC721CollectionMetadata
	TokenMetadata(tid TokenID) (Metadata, error)
}

type Trait struct {
	DisplayType string
	TraitType   string
	Value       string
}

// Metadata is stored fully on-chain; see: https://docs.opensea.io/docs/metadata-standards
type Metadata struct {
	Image           string  // URL, IPFS/Arweave path, or (commonly here) a data: URI holding the image itself.
	ImageData       string  // Raw SVG image data, if generating images on the fly. Only used if Image is empty.
	ExternalURL     string  // URL shown alongside the asset on marketplaces, linking back to the collection's own site.
	Description     string  // Human-readable description of the item. Markdown is supported.
	Name            string  // Name of the item.
	Attributes      []Trait // Attributes for the item, shown on marketplace pages for the item.
	BackgroundColor string  // Background color of the item on marketplaces. Six-character hex, no leading #.
	AnimationURL    string  // URL/data URI to a multimedia attachment for the item.
	YoutubeURL      string  // URL to a YouTube video (only used if AnimationURL is not provided).
}
