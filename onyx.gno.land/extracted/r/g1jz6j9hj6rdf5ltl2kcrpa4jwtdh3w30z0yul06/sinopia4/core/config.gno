package core

// Deploy-time configuration (mainnet plan §2.4 M-27, §5.4). Everything that
// differs per chain lives in this file, so staging (WP-H,
// deploy/realms/<chain>.json) rewrites one file and its gate can refuse an
// Onyx address in a mainnet stage. The source carries the Onyx values.

// Roles are separate on purpose (S-8): the admin can only propose
// timelocked parameter changes and never holds funds (I-1); the treasury
// only receives fees; the platform engine author only claims and
// deprecates the platform engines and registers their reserved
// fingerprints. The admin here is the bootstrap admin (= the deployer):
// admin.transfer hands it to the 2/3 multisig before minter.add (§5.7).
var (
	initialAdmin    = address("g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06")
	initialTreasury = address("g1rq2g0fmd0e0v0myz677ju3t68g46kan3r96lls")
	platformAuthor  = address("g1nm8kd8hsmp6pr7mudj2c3y2hnmnl8awx7vcz4m")
)

// reservedFP is a platform engine whose art is public before its adapter
// registers (Onyx p/ packages, the TS twins in the site bundle). Its sample
// fingerprint exists in core from the enable tx, so nobody but its author
// can ever register it (ENG-M1, I-14).
type reservedFP struct {
	name, fingerprint string
	author            address
}

// reservedFingerprints: sha256(Render(engine.SampleInput())) of each
// platform engine, from docs/engines/README.md (2026-11-04; the v2 and new
// engines 2026-11-11, each checked against its art package in
// z_reserved_fp_filetest.gno); the upload
// card's is sha256 of the v2 card (engines/upload render.gno cardSVG =
// upload.CardFingerprint, WP-F 2026-11-10; it holds no path text, so it is
// the same on every chain).
var reservedFingerprints = []reservedFP{
	{"genesis", "a9eb40c4aef4fa3d80adcccc28db007ce93f0728a5b07c3805a42777fef4e8c9", platformAuthor},
	{"kilim", "a50693874cf408b5c24c306785bab1732af0d818952c9f8f892e19cc75bdebff", platformAuthor},
	{"strata", "6b96256a0111a9508048e8226c0ba87435be040aedbfe407485b3391d46b84af", platformAuthor},
	{"rubrica", "5565972025909a38ddc9e3e19dbcd1bbc7c1be3f8fe537ea98921b4f90650d04", platformAuthor},
	{"cantiere", "69902dba328df77cea56dc6635c1489f61bf386f108a6600df0eb8a0e08f8d76", platformAuthor},
	{"giornate", "44ec27ea29c5a7c38ac90e73de6be96ddd8d3a93e6741275719d5d9a68fa0e2e", platformAuthor},
	{"upload", "0e414b46db68c64891aadfb4e1fc18ef63d9711907538b659b61b41c7d34efd1", platformAuthor},
	// v2 engines and the new engines (2026-11-11, docs/engines/integration-2026-11.md)
	{"kilimv2", "13ef738418a6f8e586c48431f2e58d0963f7f6efabc98bc74f5400806e4449d6", platformAuthor},
	{"stratav2", "93c92a8bf12fcdb8ff28c1897c00c6a61806d489cbd48e81aa27ca76076f4f41", platformAuthor},
	{"rubricav2", "94976a6b2ff033d26c685fca5ad8a0feb1023b795a7af7cf84fd6c2d7733959f", platformAuthor},
	{"cantierev2", "4f16ecd23307b6f08a518d36adf908cb7d7999d1cb4d62c5cc68ce9b4d4a2c1c", platformAuthor},
	{"giornatev2", "d4e4e9e530cc25a7ecaba21bc44444cd7958b112d6981a7b094883257321f3b1", platformAuthor},
	{"sima", "bbc39e8daf3e8c4501ebb1130b7990d7151b52d4623e2ca3de9eaf2f6633f7cc", platformAuthor},
	{"cinar", "95d4922c9f9cdb02ab96e88c1628deb179ebb8d327054ab64d12040b38c00e83", platformAuthor},
	{"katman", "f8418846a3c0632a7e89b9728127effb4567ee3523067f265ee50d7c191345ef", platformAuthor},
	{"pafta", "ecba9be924f2f04fa5d4e05f9b87d32fb5547208b05d8ca36c0fa2ece9a0c4d7", platformAuthor},
	{"ebru", "bb69fb3b0400d4e15156f9feeb400ffa882c1143872e4278c7f4fc254699c6d8", platformAuthor},
}

// staticDeniedRealms are the platform realms next to core (paths relative
// to core's parent, README package map) that can never spend an incoming
// payment. They are refused as payees and treasury from deploy on (SA-L5,
// M-17); the admin adds others with payee.deny (I-18: additions only).
var staticDeniedRealms = []string{
	"mint/v1", "market/v1", "reader", "gallery",
	"engines/genesis", "engines/kilim", "engines/strata", "engines/rubrica", "engines/cantiere",
	"engines/giornate", "engines/upload",
	"assets/v1", "randomness/drand", "offers/v1", "mint/v2", "market/v2",
	"engines/kilimv2", "engines/stratav2", "engines/rubricav2", "engines/cantierev2", "engines/giornatev2",
	"engines/sima", "engines/cinar", "engines/katman", "engines/pafta", "engines/ebru",
}
