package upload

// Deploy-time configuration (mainnet plan §2.4 M-27, §5.4): everything that
// differs per chain lives in this file, so staging (WP-H,
// deploy/realms/<chain>.json) rewrites one file. The source carries the
// Onyx values.

// author is the engine author: it signs Register (core's in-source
// reservation of the card fingerprint needs OriginCaller == Manifest.Author
// == the reserved author, I-14) and claims the engine (ClaimEngine). On
// mainnet: the platform engine-author key, never the admin or treasury.
var author = address("g1nm8kd8hsmp6pr7mudj2c3y2hnmnl8awx7vcz4m") // stage:engineAuthor

// Access policy (core I-19, docs/mainnet/engine-access-policy.md): a tool
// engine, "open". Core registers every engine closed; the bootstrap calls
// core.SetEnginePolicy(<this realm>, "open") with the author key right after
// ClaimEngine (deploy/realms/<chain>.json engines.<name>.policy).
