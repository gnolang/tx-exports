
package patusfenixv4

import (
    
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
)

const metadataURL = "https://patusworld.com/patus-testnet/Patus-fenix.webp"

var (
    collection *grc721.Token
    ledger     *grc721.PrivateLedger
    nftMeta    *metadata.Metadata
    metaLedger *metadata.Ledger
)

func init(cur realm) {
    collection, ledger = grc721.NewToken(
        "Patus Fenix Test",
        "PFT",
        0,
        cur,
    )

    nftMeta, metaLedger = metadata.NewMetadata(ledger)
}

// MintTest acuna un unico NFT de prueba.
// La wallet que ejecuta la funcion recibe el NFT.
func MintTest(cur realm) string {
    if collection.TotalSupply() >= 1 {
        return "Patus Fenix has already been minted"
    }

    owner := cur.Previous().Address()

    if err := ledger.Mint(owner, "1"); err != nil {
        return err.Error()
    }

    if err := metaLedger.SetTokenURI("1", metadataURL); err != nil {
        return err.Error()
    }

    return "Patus Fenix minted successfully"
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
    return "Patus Fenix - GRC721 Test NFT on Onyx"
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
        "name": "Patus Phoenix - Test NFT",
        "description": "Test NFT for Patus World on Gno.land Onyx Testnet. No commercial value.",
        "image": "https://patusworld.com/patus-testnet/Patus-fenix.webp",
        "externalUrl": "https://patusworld.com",
        "attributes": [
            {"traitType": "Body", "value": "Phoenix"},
            {"traitType": "Background", "value": "Fire"},
            {"traitType": "Tech", "value": "Test"},
            {"traitType": "System", "value": "Onyx"},
            {"traitType": "Error", "value": "404"}
        ]
    }`, nil
}
