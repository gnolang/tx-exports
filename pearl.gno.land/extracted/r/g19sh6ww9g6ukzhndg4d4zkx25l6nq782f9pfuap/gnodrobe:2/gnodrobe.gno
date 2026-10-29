package gnodrobe

import (
  grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
)

var nft *grc721.MetadataNFT

func init(cur realm) {
  nft = grc721.NewNFTWithMetadata(0, cur, "GnoDrobe Collection", "GDG")
}

func Name() string { return nft.Name() }
func Symbol() string { return nft.Symbol() }
