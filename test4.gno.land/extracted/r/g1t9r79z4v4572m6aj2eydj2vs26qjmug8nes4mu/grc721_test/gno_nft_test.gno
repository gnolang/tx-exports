package grc721_test

import (
	"std"
	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/json"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g1t9r79z4v4572m6aj2eydj2vs26qjmug8nes4mu"
	grc721_test              = NewNFTWithMetadata("grc721_test", "GNT")
)

func init() {
}

func mintNFT(owner std.Address, n uint64) {
	count := grc721_test.TokenCount()
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
	balance, err := grc721_test.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err)
	}

	return balance
}

func Name() string {
	return grc721_test.Name()
}

func Symbol() string {
	return grc721_test.Symbol()
}

func TokenURI(tid grc721.TokenID) string {
	tokenURI, err := grc721_test.TokenURI(tid)
	if err != nil {
		panic(err)
	}

	return tokenURI
}

func TokenMetadata(tid grc721.TokenID) string {
	metadata, err := grc721_test.TokenMetadata(tid)
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
	owner, err := grc721_test.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return grc721_test.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := grc721_test.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := grc721_test.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := grc721_test.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err)
	}
}

func SafeTransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := grc721_test.SafeTransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := grc721_test.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func SetTokenURI(tid grc721.TokenID, tURI grc721.TokenURI) bool {
	result, err := grc721_test.SetTokenURI(tid, tURI)
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
	err := grc721_test.Burn(tid)
	if err != nil {
		panic(err)
	}
}

func mint(to std.Address, tid grc721.TokenID) error {
	err := grc721_test.Mint(to, tid)
	if err != nil {
		return err
	}

	attributes := []grc721.Trait{}
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type1",
		Value:       "Value1",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type2",
		Value:       "Value2",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type3",
		Value:       "Value3",
	})
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "Type4",
		Value:       "Value4",
	})

	grc721_test.SetTokenMetadata(tid, grc721.Metadata{
		Name:            "grc721_test",
		Description:     "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam nec purus nec nunc tincidunt ultricies. Nullam nec purus nec nunc tincidunt ultricies.",
		Attributes:      attributes,
		BackgroundColor: "#FFFF00",
	})

    grc721_test.SetTokenURI(tid, "https://raw.githubusercontent.com/gnolang/branding/3de1fcff368df228d46b87ec476a3e1485e145c9/svg/Logo%20Short%20On%20Black%20Background.svg")

	return nil
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return grc721_test.RenderHome()
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
