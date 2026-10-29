package onbloc_test

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/json"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g1kpptltmd8jmwq5et5udh3ld8qq4ksqm9kj0vs4"
	Onbloc_Test              = NewNFTWithMetadata("Onbloc_Test", "OBL")
)

func init() {
}

func mintNFT(owner std.Address, n uint64) {
	count := Onbloc_Test.TokenCount()
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
	balance, err := Onbloc_Test.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err)
	}

	return balance
}

func Name() string {
	return Onbloc_Test.Name()
}

func Symbol() string {
	return Onbloc_Test.Symbol()
}

func TokenURI(tid grc721.TokenID) string {
	tokenURI, err := Onbloc_Test.TokenURI(tid)
	if err != nil {
		panic(err)
	}

	return tokenURI
}

func TokenMetadata(tid grc721.TokenID) string {
	metadata, err := Onbloc_Test.TokenMetadata(tid)
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
	owner, err := Onbloc_Test.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return Onbloc_Test.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := Onbloc_Test.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := Onbloc_Test.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := Onbloc_Test.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err)
	}
}

func SafeTransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := Onbloc_Test.SafeTransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := Onbloc_Test.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func SetTokenURI(tid grc721.TokenID, tURI grc721.TokenURI) bool {
	result, err := Onbloc_Test.SetTokenURI(tid, tURI)
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
	err := Onbloc_Test.Burn(tid)
	if err != nil {
		panic(err)
	}
}

func mint(to std.Address, tid grc721.TokenID) error {
	err := Onbloc_Test.Mint(to, tid)
	if err != nil {
		return err
	}

	attributes := []grc721.Trait{}
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type1",
		Value:       "Alien",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type2",
		Value:       "Police Uniform",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type3",
		Value:       "Handsome",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Typ4",
		Value:       "Very extremely red",
	})

	Onbloc_Test.SetTokenMetadata(tid, grc721.Metadata{
		Name:            "Onbloc_Test",
		Description:     "A GnoPunk is a 24x24 pixel, 8-bit-style unique avatar that comes in the form of an NFT. Their creation began as an experiment, conducted by software developers Matt Hall and John Watkinson in 2017.",
		Attributes:      attributes,
		BackgroundColor: "#FFFF00",
	})

    Onbloc_Test.SetTokenURI(tid, "https://raw.githubusercontent.com/onbloc/gno-token-resource/refs/heads/main/grc20/images/gno_land_r_onbloc_bar.svg")

	return nil
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return Onbloc_Test.RenderHome()
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
