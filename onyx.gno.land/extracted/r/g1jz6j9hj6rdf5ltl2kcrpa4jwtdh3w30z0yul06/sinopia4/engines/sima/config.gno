package sima

// Deploy-time configuration (mainnet plan §3.1, M-8, M-10, M-27). Staging
// (WP-H, deploy/realms/<chain>.json) rewrites this file per chain; the
// source carries the Onyx values.

// author is the platform engine-author key (S-8: no other role). It signs
// Register and ClaimEngine (core requires signer == Manifest.Author, I-14).
var author = address("g1nm8kd8hsmp6pr7mudj2c3y2hnmnl8awx7vcz4m") // stage:engineAuthor

// AuthorFeeBps is the author's fee on primary and secondary sales of
// collections by other creators (engine.Manifest.FeeBps; waived for the
// author's own collections, capped by core's engine-fee cap). Platform
// engines: 1 %.
const AuthorFeeBps = 100

// Access policy (core I-19, docs/mainnet/engine-access-policy.md): a
// signature engine, "closed". Core registers every engine closed and the
// bootstrap leaves it so (deploy/realms/<chain>.json engines.sima.policy), so
// only the author key opens collections with it; the author may later
// license creators (core.GrantLicence) without a new deploy.
