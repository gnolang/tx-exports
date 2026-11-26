// Package tavernboard implements TavernBoard — an on-chain micro-bounty,
// isolated sub-realm escrow, stake-backed reviewer quorum, and composable
// builder reputation realm built for Gno.land v1.8 (Onyx & Mainnet).
//
// Key Gno.land v1.8 capabilities demonstrated:
//   - Per-bounty cryptographically isolated Sub-Realm Escrow Vaults via
//     cur.Sub("escrow/<id>") and per-dispute Reviewer Stake Vaults via
//     cur.Sub("stake/<id>"), enforced at the GnoVM banker level.
//   - Direct EOA funding guarded by cur.Previous().IsUserCall() +
//     BankerTypeOriginSend, plus composable DAO / cross-realm top-ups via
//     chain.DerivePkgSubAddr + SyncBountyVault.
//   - Strict Interrealm v2 security hygiene: no leaked mutable pointers,
//     no unsafe.PreviousRealm(), single-denom banker.GetCoin reads, and
//     slot-aware Markdown sanitization via p/nt/markdown/sanitize/v0.
//   - Rich gnoweb-native multi-route Render(path) UI with on-chain SVG
//     Guild Crests, Escrow Progress Cards, one-click txlink actions, and
//     permissionless storage-deposit reclamation via ArchiveClosedBounty.
package tavernboard
