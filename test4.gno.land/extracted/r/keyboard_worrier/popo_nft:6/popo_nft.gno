package popo_nft

import (
	"std"

	"gno.land/p/demo/grc/grc721"
	"gno.land/p/demo/json"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	pusers "gno.land/p/demo/users"
)

var (
	admin std.Address = "g13qpel38unrma0nyrj29tr903pq7dpeecsmlu8z"
	popo              = grc721.NewNFTWithMetadata("PopoNFT", "POPO")
)

// func init() {
// 	mintNNFT(admin, 20)                                     // @administrator (20)
// 	mintNNFT("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", 5) // @test (5)
// }

func mintNNFT(owner std.Address, n uint64) {
	count := popo.TokenCount()
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
	balance, err := popo.BalanceOf(users.Resolve(user))
	if err != nil {
		panic(err)
	}

	return balance
}

func Name() string {
	return popo.Name()
}

func Symbol() string {
	return popo.Symbol()
}

func TokenURI(tid grc721.TokenID) string {
	tokenURI, err := popo.TokenURI(tid)
	if err != nil {
		panic(err)
	}

	return tokenURI
}

func TokenMetadata(tid grc721.TokenID) string {
	metadata, err := popo.TokenMetadata(tid)
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
	owner, err := popo.OwnerOf(tid)
	if err != nil {
		panic(err)
	}

	return owner
}

func IsApprovedForAll(owner, user pusers.AddressOrName) bool {
	return popo.IsApprovedForAll(users.Resolve(owner), users.Resolve(user))
}

func GetApproved(tid grc721.TokenID) std.Address {
	addr, err := popo.GetApproved(tid)
	if err != nil {
		panic(err)
	}

	return addr
}

// Setters

func Approve(user pusers.AddressOrName, tid grc721.TokenID) {
	err := popo.Approve(users.Resolve(user), tid)
	if err != nil {
		panic(err)
	}
}

func SetApprovalForAll(user pusers.AddressOrName, approved bool) {
	err := popo.SetApprovalForAll(users.Resolve(user), approved)
	if err != nil {
		panic(err)
	}
}

func SafeTransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := popo.SafeTransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to pusers.AddressOrName, tid grc721.TokenID) {
	err := popo.TransferFrom(users.Resolve(from), users.Resolve(to), tid)
	if err != nil {
		panic(err)
	}
}

func SetTokenURI(tid grc721.TokenID, tURI grc721.TokenURI) bool {
	result, err := popo.SetTokenURI(tid, tURI)
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
	err := popo.Burn(tid)
	if err != nil {
		panic(err)
	}
}

func mint(to std.Address, tid grc721.TokenID) error {
	err := popo.Burn(tid)
	if err != nil {
		return err
	}

	err = popo.Mint(to, tid)
	if err != nil {
		return err
	}

	attributes := []grc721.Trait{}
	attributes = append(attributes, grc721.Trait{
		DisplayType: "string",
		TraitType:   "size",
		Value:       "M",
	})

	popo.SetTokenMetadata(tid, grc721.Metadata{
		Name:            "Popo",
		Description:     "PoPo NFT",
		Image:           "",
		ImageData:       "",
		ExternalURL:     "",
		Attributes:      attributes,
		BackgroundColor: "#FFFF00",
		AnimationURL:    "",
		YoutubeURL:      "",
	})

	return nil
}

// Render

func Render(path string) string {
	switch {
	case path == "":
		return popo.RenderHome()
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
