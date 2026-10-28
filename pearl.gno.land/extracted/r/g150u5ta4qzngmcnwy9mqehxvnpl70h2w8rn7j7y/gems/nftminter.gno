package gems

import (
	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	"gno.land/p/g150u5ta4qzngmcnwy9mqehxvnpl70h2w8rn7j7y/gemsart"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var nft *grc721.MetadataNFT
var tree avl.Tree
var nextID seqid.ID

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, "Gems", "GEMS")
	tree.Set("x", 1)
	_ = nextID
}

func Name() string { return nft.Name() }
func Test() string { return ufmt.Sprintf("%s", gemsart.StoneNamesCSV()) }
