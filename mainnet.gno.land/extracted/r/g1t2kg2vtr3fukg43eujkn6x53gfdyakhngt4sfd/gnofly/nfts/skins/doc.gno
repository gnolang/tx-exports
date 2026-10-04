// v0 - Unaudited: This is an initial version that has not yet been formally audited.
// Use in production at your own risk.
//
// Package skins is the catalog of plane skins of gnofly, a multiplayer plane
// game, and the tokens of the skins sold. Every skin bought is a GRC721
// token on gno.land/p/nt/grc721/v0, one per buyer and design.
//
// The tokens are soulbound: there is no TransferFrom, no Approve and no
// SetApprovalForAll, and the token object is not exported, so nothing can
// move a skin away from its buyer. Its owner can Burn it, which gives back
// the storage deposit (not the price).
//
// Supply is unlimited by default; an admin can cap a design. Classic, the
// look every pilot flies by default, is free and is not a token.
//
// Writers:
//
//   - anyone buys a skin with its price attached (Buy), and burns their own
//     (Burn);
//   - the admins of the game realm edit the catalog (SetSkin, SetSkinListed).
//
// The realm keeps no roles and no money: admins and treasury are those of
// gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0, and every
// sale is forwarded to the treasury in the same transaction.
//
// A token stores only its owner (the ledger), its design and an entry in the
// buyer's list: no metadata record and no URI. TokenURI is computed from the
// design. Reads are plain functions meant for vm/qeval: CatalogJSON, SkinsOf,
// OwnerOf, SkinOf, TokenURI, Render.
package skins
