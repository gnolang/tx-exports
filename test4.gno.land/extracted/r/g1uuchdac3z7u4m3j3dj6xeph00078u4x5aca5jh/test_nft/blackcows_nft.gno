package TEST_NFT

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/json"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g1uuchdac3z7u4m3j3dj6xeph00078u4x5aca5jh"
	blackcow              = NewNFTWithMetadata("TestMint", "TEST")
)

func init() {
}

func mintNFT(owner std.Address, n uint64) {
	count := blackcow.TokenCount()
	for i := count; i < count+n; i++ {
		tid := grc721.TokenID(ufmt.Sprintf("%d", i))
		err := mint(owner, tid)
		if err != nil {
			panic(err)
		}
	}
}

// Getters

func BalanceOf(user pusers.AddressOrName) uint64 {
	balance, err := blackcow.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err)
	}

	return balance
}

func Name() string {
	return blackcow.Name()
}

func Symbol() string {
	return blackcow.Symbol()
}

func TokenURI(tid grc721.TokenID) string {
	tokenURI, err := blackcow.TokenURI(tid)
	if err != nil {
		panic(err)
	}

	return tokenURI
}

func TokenMetadata(tid grc721.TokenID) string {
	metadata, err := blackcow.TokenMetadata(tid)
	if err != nil {
		panic(err)
	}

	metadataNode := json.ObjectNode("", nil)

	metadataNode.AppendObject("image", json.StringNode("image", metadata.Image))
	metadataNode.AppendObject("imageData", json.StringNode("imageData", metadata.ImageData))
	metadataNode.AppendObject("externalUrl", json.StringNode("externalUrl", metadata.ExternalURL))
	metadataNode.AppendObject("description", json.StringNode("description", metadata.Description))
	metadataNode.AppendObject("name", json.StringNode("name", metadata.Name))
	metadataNode.AppendObject("backgroundColor", json.StringNode("backgroundColor", metadata.BackgroundColor))
	metadataNode.AppendObject("animationUrl", json.StringNode("animationUrl", metadata.AnimationURL))
	metadataNode.AppendObject("youtubeUrl", json.StringNode("youtubeUrl", metadata.YoutubeURL))

	attributesNode := json.ArrayNode("attributes", nil)

	for _, trait := range metadata.Attributes {
		traitNode := json.ObjectNode("", nil)
		traitNode.AppendObject("displayType", json.StringNode("displayType", trait.DisplayType))
		traitNode.AppendObject("traitType", json.StringNode("traitType", trait.TraitType))
		traitNode.AppendObject("value", json.StringNode("value", trait.Value))

		attributesNode.AppendArray(traitNode)
	}

	metadataNode.AppendObject("attributes", attributesNode)

	metadataStr, err := json.Marshal(metadataNode)
	if err != nil {
		panic(err)
	}

	return string(metadataStr)
}

func OwnerOf(tid grc721.TokenID) std.Address {
	owner, err := blackcow.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return blackcow.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := blackcow.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := blackcow.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := blackcow.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err)
	}
}

func SafeTransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := blackcow.SafeTransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := blackcow.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func SetTokenURI(tid grc721.TokenID, tURI grc721.TokenURI) bool {
	result, err := blackcow.SetTokenURI(tid, tURI)
	if err != nil {
		panic(err)
	}

	return result
}

// Admin

func Mint(to pusers.AddressOrName, tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := mint(users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func Burn(tid grc721.TokenID) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := blackcow.Burn(tid)
	if err != nil {
		panic(err)
	}
}

func mint(to std.Address, tid grc721.TokenID) error {
	err := blackcow.Mint(to, tid)
	if err != nil {
		return err
	}

	attributes := []grc721.Trait{}
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Race",
		Value:       "Alien",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Race",
		Value:       "Police Uniform",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Face",
		Value:       "Handsome",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Background",
		Value:       "Very extremely red",
	})

	blackcow.SetTokenMetadata(tid, grc721.Metadata{
		Name:            "BlackCow",
		Description:     "A GnoPunk is a 24x24 pixel, 8-bit-style unique avatar that comes in the form of an NFT. Their creation began as an experiment, conducted by software developers Matt Hall and John Watkinson in 2017.",
		Attributes:      attributes,
		BackgroundColor: "#FFFF00",
	})

    blackcow.SetTokenURI(tid, "https://i.namu.wiki/i/yRO1u5KjySi1CtJmt6TQMIqcbXiejx7Tr-OTMv419lYLiCZYBClOxwBY2n0nz06W-9WFg9-tV2DWWPyWZh-PlOb_c1jF7P69_EAOSLuy8cUq3BOVd4o3FniIdckuWGVQFX2s-_m_XBTAMDepZ240eg.webp")

	return nil
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return blackcow.RenderHome()
	default:
		return "404\n"
	}
}

// Util

func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}
