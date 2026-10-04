// v0 - Unaudited: This is an initial version that has not yet been formally audited.
// Use in production at your own risk.
//
// Package planes is a collection of 777 plane NFTs that pilots fly in
// gnofly, a multiplayer plane game. It is a GRC721 token built on
// gno.land/p/nt/grc721/v0 with the royalty extension.
//
// Every plane is drawn in a table committed with the realm (table.gno): a
// name, one of the nine models the game client draws, a pilot (none or a
// gnome), three colours, a tier and the colour of its laser, the shots
// every pilot sees it fire. The designs stay procedural in the client; the
// token stores only these traits. Id 777 is the super-gnome, a
// 1/1 that is a gnome flying like a superhero rather than a plane. The table
// is public; which ids a mint gets is drawn at random among the ones left,
// 1 to 7 per call (draw.gno).
//
// Three kinds of callers write to it:
//
//   - anyone mints the next plane with the price attached (Mint), transfers,
//     approves and burns their planes (TransferFrom, Approve,
//     SetApprovalForAll, Burn);
//   - the admins of the game realm open and close the mint and tune its
//     price, its per-wallet cap, the image URL and the royalty (SetMintOpen,
//     SetPrice, SetMintCap, SetImageBase, SetRoyaltyBps);
//   - nobody else: there is no reserve and no airdrop.
//
// The realm keeps no roles and no money of its own. The admins are those of
// gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0, asked
// at the time of each call, and every mint is forwarded to its treasury in
// the same transaction. The royalty of a resale, 5% by default, names the
// treasury too.
//
// Reads are plain functions meant for vm/qeval. The ones ending in JSON
// return a single string holding a JSON document. PlanesOf and OwnerOf are
// what the game server reads: ownership is the only on-chain fact of a
// plane, which one a pilot flies is picked in the game's hangar and checked
// against OwnerOf by the server. Render exposes the
// same data as markdown for gnoweb. The read side of the token and of its
// royalty extension is exported as Token and Royalties, for other realms.
// No metadata is stored per token: TokenMetadata and TokenURI are computed
// from the table and the image base on every read.
//
// Storage is paid for at deploy, so the realm is kept small: the table is one
// string read in place, refusals are string constants, and the settings are
// read through CollectionJSON rather than one getter each.
package planes
