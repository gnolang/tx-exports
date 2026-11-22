package patusfenixv8

import (
    "gno.land/p/nt/grc721/v0"
    "gno.land/p/nt/grc721/metadata/v0"
)

var (
    collection *grc721.Token
    ledger     *grc721.PrivateLedger
    nftMeta    *metadata.Metadata
    metaLedger *metadata.Ledger
)

func init(cur realm) {
    collection, ledger = grc721.NewToken(
        "Patus World V8",
        "PW8",
        0,
        cur,
    )
    nftMeta, metaLedger = metadata.NewMetadata(ledger)
}

// Devuelve la imagen correspondiente a cada NFT.
func imageFor(tokenID string) string {
    switch tokenID {
    case "1":
        return "https://patusworld.com/patus-testnet/Patus-fenix.webp"
    case "2":
        return "https://patusworld.com/patus-testnet/ferpect.webp"
    case "3":
        return "https://patusworld.com/patus-testnet/pretending-to-be.webp"
    default:
        return ""
    }
}

// Acuna el siguiente NFT disponible, hasta un maximo de tres.
func MintTest(cur realm) string {
    supply := collection.TotalSupply()

    if supply >= 3 {
        return "All three Patus World V8 NFTs have been minted"
    }

    var tokenID string
    switch supply {
    case 0:
        tokenID = "1"
    case 1:
        tokenID = "2"
    default:
        tokenID = "3"
    }

    owner := cur.Previous().Address()

    if err := ledger.Mint(owner, grc721.TokenID(tokenID)); err != nil {
        return err.Error()
    }

    if err := metaLedger.SetTokenURI(
        grc721.TokenID(tokenID),
        imageFor(tokenID),
    ); err != nil {
        panic(err)
    }

    return "Patus World V8 NFT minted successfully"
}

func TokenURI(tokenID string) string {
    uri, err := nftMeta.TokenURI(grc721.TokenID(tokenID))
    if err != nil {
        return ""
    }
    return uri
}

func TotalSupply() int64 {
    return collection.TotalSupply()
}

func OwnerOf(tokenID string) string {
    owner, err := collection.OwnerOf(grc721.TokenID(tokenID))
    if err != nil {
        return ""
    }
    return owner.String()
}

func TokenMetadata(tokenID grc721.TokenID) (string, error) {
    _, err := collection.OwnerOf(tokenID)
    if err != nil {
        return "", err
    }

    switch string(tokenID) {
    case "1":
        return `{
            "name": "Patus Fenix",
            "description": "Patus World V8 test NFT. No commercial value.",
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

    case "2":
        return `{
            "name": "Patus Ferpect",
            "description": "Patus World V8 test NFT. No commercial value.",
            "image": "https://patusworld.com/patus-testnet/ferpect.webp",
            "externalUrl": "https://patusworld.com",
            "attributes": [
                {"traitType": "Body", "value": "Ferpect Duck"},
                {"traitType": "Background", "value": "Blue"},
                {"traitType": "Tech", "value": "Test"},
                {"traitType": "System", "value": "Onyx"},
                {"traitType": "Error", "value": "404"}
            ]
        }`, nil

    case "3":
        return `{
            "name": "Patus Pretending to Be",
            "description": "Patus World V8 test NFT. No commercial value.",
            "image": "https://patusworld.com/patus-testnet/pretending-to-be.webp",
            "externalUrl": "https://patusworld.com",
            "attributes": [
                {"traitType": "Body", "value": "Pretending Duck"},
                {"traitType": "Background", "value": "Blue"},
                {"traitType": "Tech", "value": "Test"},
                {"traitType": "System", "value": "Onyx"},
                {"traitType": "Error", "value": "404"}
            ]
        }`, nil
    }

    return "", nil
}

func TransferFrom(cur realm, from address, to address, tokenID string) {
    spender := cur.Previous().Address()

    if err := ledger.TransferFrom(
        spender,
        from,
        to,
        grc721.TokenID(tokenID),
    ); err != nil {
        panic(err)
    }
}

func Render(path string) string {
    return "Patus World V8 - Three NFT GRC721 Test Collection"
}
