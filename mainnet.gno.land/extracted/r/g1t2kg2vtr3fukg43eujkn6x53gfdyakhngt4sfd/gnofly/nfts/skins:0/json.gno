package skins

import (
	"errors"
	"strings"

	"gno.land/p/nt/grc721/v0"
	"gno.land/p/onbloc/json/v0"
)

// CatalogJSON returns every design, sorted by id, as a JSON array:
//
//	[ { "id": "baron", "name": "Red Baron", "model": "biplane", "pilot": "none",
//	    "body": "#c1121f", "wing": "#780000", "accent": "#fdf0d5",
//	    "price": 1000000, "listed": true, "minted": 3, "maxSupply": 0 } ]
//
// The output has no whitespace. maxSupply 0 is unlimited. Classic, the free
// look, is not in it: the client draws it without a token.
func CatalogJSON() string {
	items := []*json.Node{}
	designs.Iterate("", "", func(_ string, v any) bool {
		d := v.(*design)
		b := json.Builder().
			WriteString("id", d.id).
			WriteString("name", d.name).
			WriteString("model", d.model).
			WriteString("pilot", d.pilot).
			WriteString("body", d.body).
			WriteString("wing", d.wing).
			WriteString("accent", d.accent).
			WriteNumber("price", float64(d.price)).
			WriteBool("listed", d.listed).
			WriteNumber("minted", float64(d.minted)).
			WriteNumber("maxSupply", float64(d.maxSupply))
		items = append(items, b.Node())
		return false
	})
	return encode(json.ArrayNode("", items))
}

// SkinsOf returns the designs addr owns a token of, sorted by id, as a JSON
// array: ["baron","goldie"]. It is [] for an address without skins.
func SkinsOf(addr address) string {
	ids := []*json.Node{}
	prefix := addr.String() + "/"
	if validAddress(addr) {
		// Keys sort as "<addr>/<design>": the designs of addr are one range,
		// "/" + 1 is "0".
		owned.Iterate(prefix, addr.String()+"0", func(key string, _ any) bool {
			ids = append(ids, json.StringNode("", strings.TrimPrefix(key, prefix)))
			return false
		})
	}
	return encode(json.ArrayNode("", ids))
}

// The read functions a wallet calls take a grc721.TokenID and return an
// error rather than panic, the way Adena calls them: OwnerOf("1") into two
// values, TokenURI("1") as the image it shows, TokenMetadata("1") as JSON
// for the traits. The errors are made on the call, not stored (errors.gno).

// OwnerOf returns who owns skin token tid, or an error when there is none.
func OwnerOf(tid grc721.TokenID) (address, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	return ownerOf(id), nil
}

// BalanceOf returns how many skin tokens addr owns, one per design at most.
func BalanceOf(addr address) (int64, error) {
	return token.BalanceOf(addr)
}

// TokenMetadata returns the metadata of skin token tid as JSON, the same for
// every token of a design, with the keys Adena reads:
//
//	{"name":"Red Baron","description":"A gnofly skin, a biplane. ...",
//	 "image":"https://gnofly.xyz/nft/skins/baron.png",
//	 "attributes":[{"traitType":"model","value":"biplane"}, ...]}
func TokenMetadata(tid grc721.TokenID) (string, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	d := getDesign(skinOf(id))
	if d == nil {
		return "", errors.New(errNotMinted)
	}
	pilot := ""
	if d.pilot == "gnome" {
		pilot = " flown by a gnome"
	}
	b := json.Builder().
		WriteString("name", d.name).
		WriteString("description", "A gnofly skin, a "+d.model+pilot+". Bound to its buyer: it cannot be transferred.").
		WriteString("image", uriBase+d.id+".png").
		WriteArray("attributes", func(ab *json.ArrayBuilder) {
			for _, t := range [][2]string{
				{"model", d.model}, {"pilot", d.pilot}, {"body", d.body}, {"wing", d.wing},
				{"accent", d.accent}, {"soulbound", "yes"},
			} {
				ab.WriteObject(func(o *json.NodeBuilder) {
					o.WriteString("traitType", t[0]).WriteString("value", t[1])
				})
			}
		})
	return encode(b.Node()), nil
}

// mintedID reads a token id, "1" and up in decimal, and checks it exists.
func mintedID(tid grc721.TokenID) (int64, error) {
	s := string(tid)
	n := int64(0)
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' || i > 15 || (i == 0 && s[i] == '0') {
			return 0, errors.New(errNotMinted)
		}
		n = n*10 + int64(s[i]-'0')
	}
	if n == 0 || ownerOf(n) == "" {
		return 0, errors.New(errNotMinted)
	}
	return n, nil
}

// SkinOf returns the design of skin token id, "" when there is no such token.
func SkinOf(id int64) string {
	return skinOf(id)
}

// TokenURI returns the image of skin token tid,
// "https://gnofly.xyz/nft/skins/<design>.png": what a wallet shows (Adena
// puts it in an <img>). The metadata is TokenMetadata, or
// "https://gnofly.xyz/nft/skins/<design>.json" on the website. It is
// computed, not stored: a token costs no URI in deposit.
func TokenURI(tid grc721.TokenID) (string, error) {
	id, err := mintedID(tid)
	if err != nil {
		return "", err
	}
	return uriBase + skinOf(id) + ".png", nil
}

// encode marshals a document built above; it cannot fail on one.
func encode(n *json.Node) string {
	out, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	return string(out)
}
