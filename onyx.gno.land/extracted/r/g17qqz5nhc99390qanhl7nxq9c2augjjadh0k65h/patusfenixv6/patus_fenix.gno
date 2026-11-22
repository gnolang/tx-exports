
package patusfenixv6

import (
    
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
)

const metadataURL = "https://arweave.net/VF1LH2dL7FKIRm3U90Tgdu8IHPDso6fg0xZteYEhE3c"

var (
    collection *grc721.Token
    ledger     *grc721.PrivateLedger
    nftMeta    *metadata.Metadata
    metaLedger *metadata.Ledger
)

func init(cur realm) {
    collection, ledger = grc721.NewToken(
        "Patus Unclassified Files",
        "PUF",
        0,
        cur,
    )

    nftMeta, metaLedger = metadata.NewMetadata(ledger)
}

// MintTest acuna un unico NFT de prueba.
// La wallet que ejecuta la funcion recibe el NFT.
func MintTest(cur realm) string {
    if collection.TotalSupply() >= 1 {
        return "Patus Unclassified Files has already been minted"
    }

    owner := cur.Previous().Address()

    if err := ledger.Mint(owner, "1"); err != nil {
        return err.Error()
    }

    if err := metaLedger.SetTokenURI("1", metadataURL); err != nil {
        return err.Error()
    }

    return "Patus Unclassified Files minted successfully"
}

// Permite consultar la URL de metadatos del NFT.
func TokenURI(tokenID string) string {
    uri, err := nftMeta.TokenURI(grc721.TokenID(tokenID))
    if err != nil {
        return ""
    }
    return uri
}

// Permite consultar cuantos NFT existen.
func TotalSupply() int64 {
    return collection.TotalSupply()
}

// Pagina informativa del contrato.
func Render(path string) string {
    return "Patus Unclassified Files - GRC721 Test NFT on Onyx"
}

// Devuelve la direccion propietaria del NFT.
func OwnerOf() string {
    owner, err := collection.OwnerOf("1")
    if err != nil {
        return ""
    }
    return owner.String()
}

// Devuelve los metadatos del NFT.
func TokenMetadata(tokenID grc721.TokenID) (string, error) {
    _, err := collection.OwnerOf(tokenID)
    if err != nil {
        return "", err
    }

    return `{
        "name": "Patus Unclassified Files",
        "description": "Test NFT for Patus World on Gno.land Onyx Testnet. No commercial value.",
        "image": "https://arweave.net/VF1LH2dL7FKIRm3U90Tgdu8IHPDso6fg0xZteYEhE3c",
        "externalUrl": "https://patusworld.com",
        "attributes": [
            {"traitType": "Body", "value": "Unclassified Duck"},
            {"traitType": "Background", "value": "Unclassified Files"},
            {"traitType": "Tech", "value": "Test"},
            {"traitType": "System", "value": "Onyx"},
            {"traitType": "Error", "value": "404"}
        ]
    }`, nil
}


// Transfiere un NFT mediante el mecanismo oficial GRC721.
func TransferFrom(cur realm, from address, to address, tokenID string) {
    spender := cur.Previous().Address()

    if err := ledger.TransferFrom(spender, from, to, grc721.TokenID(tokenID)); err != nil {
        panic(err)
    }
}
