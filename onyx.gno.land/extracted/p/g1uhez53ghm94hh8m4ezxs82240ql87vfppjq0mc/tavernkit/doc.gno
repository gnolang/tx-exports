// Package tavernkit is a reusable, stateless pure Gno package powering
// TavernBoard and any third-party Gno.land realm that needs:
//
//   - Dust-free basis-point milestone escrow allocation (integer math only)
//   - Deterministic on-chain builder & reviewer reputation scoring and Craft Tiers
//   - Stake-weighted quorum verdict evaluation for milestone disputes
//   - On-chain SVG Guild Crest and Escrow Progress Card rendering (via p/nt/svg/v0)
//   - Safe GNOT coin formatting and address abbreviation utilities
//
// Because tavernkit lives in /p/ and carries zero mutable state, any Gno realm,
// DAO, or grant program can import it directly to compose milestone escrow math,
// verify Craft Tiers, or render on-chain SVG achievement badges inside gnoweb.
package tavernkit
