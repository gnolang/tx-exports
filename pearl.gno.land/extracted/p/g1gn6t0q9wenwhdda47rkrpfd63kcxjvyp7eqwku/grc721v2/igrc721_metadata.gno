package grc721v2

type IGRC721CollectionMetadata interface {
	Name() string
	Symbol() string
}

type IGRC721Metadata interface {
	IGRC721CollectionMetadata
	TokenURI(tid TokenID) (string, error)
}

type IGRC721MetadataOnchain interface {
	IGRC721CollectionMetadata
	TokenMetadata(tid TokenID) (Metadata, error)
}

type Trait struct {
	DisplayType string
	TraitType   string
	Value       string
}

type Metadata struct {
	Image           string
	ImageData       string
	ExternalURL     string
	Description     string
	Name            string
	Attributes      []Trait
	BackgroundColor string
	AnimationURL    string
	YoutubeURL      string
}
