package bls254

// The drand "evmnet" chain's identity: the four facts about the beacon that are
// properties of the CHAIN rather than of any code here.
//
// THIS IS THE ONE PLACE THE GROUP PUBLIC KEY IS WRITTEN DOWN. Before this file it
// appeared only in test files, duplicated across drandvectors_test.gno and
// drandgas_test.gno; both now read it from here, and r/splash/beacon decodes it
// once at init. A second copy of a verification key is a second thing to get
// wrong, and the wrong one would reject every real signature or -- far worse in a
// different scheme -- accept a forged one.
//
// IT LIVES IN THIS PURE PACKAGE, NOT IN THE REALM, because it describes drand,
// not SPLASH. The realm that consumes it is one consumer; the tests are another;
// r/splash/arcade/raffle needs PeriodSeconds for a build-time guard and must not
// have to import a realm to get it.
//
// PROVENANCE, AND IT IS NOT DOCUMENTATION. Every value below was read from
// drand's own /info endpoint and is byte-identical from three independent relays
// -- api.drand.sh, api2.drand.sh and drand.cloudflare.com. The verbatim curl
// commands and responses are recorded twice, in testdata/drand/rounds.raw.txt
// here and in r/splash/beacon/testdata/drand-rounds.raw.txt.
const (
	// DrandEvmnetChainHash identifies the chain. It is not used in verification
	// -- the signed message is keccak256(uint64 round) and nothing else -- so it
	// is here to name what a signature belongs to, and to make a wrong-chain
	// fixture obvious to a reader rather than only to the pairing check.
	DrandEvmnetChainHash = "04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3"

	// DrandEvmnetScheme is the scheme ID, and it is the reason drandcurve.gno
	// uses SVDW and not SSWU. See DrandDST.
	DrandEvmnetScheme = "bls-bn254-unchained-on-g1"

	// DrandEvmnetPeriodSeconds is the cadence: ONE ROUND EVERY THREE SECONDS.
	//
	// THIS NUMBER IS THE ONE THAT BREAKS THINGS. The SPLASH beacon it replaces
	// ran at five minutes, so every round-denominated duration anywhere in this
	// repository was 100x wrong the moment the key changed, while still being
	// dimensionally consistent and therefore invisible to the build guards that
	// compared rounds to rounds. Any realm expressing a DURATION in rounds must
	// multiply by this constant and compare against seconds. See
	// r/splash/beacon/DRAND-MIGRATION.md section 6.
	DrandEvmnetPeriodSeconds = 3

	// DrandEvmnetGenesisTime is round 1's unix timestamp, so round r is signed at
	// DrandEvmnetGenesisTime + DrandEvmnetPeriodSeconds*(r-1).
	//
	// NO REALM ON THIS TOOLCHAIN CAN USE THIS FOR ANYTHING, and that is worth
	// saying where someone will look for it: there is no block-timestamp getter,
	// so a realm cannot compare a round to the wall clock. It is here so that a
	// human or a test harness can, and so that the round <-> time mapping the
	// whole pin argument rests on is written down next to the period.
	DrandEvmnetGenesisTime = 1727521075

	// DrandEvmnetPubKeyHex is the 128-byte G2 group public key in EIP-197 wire
	// order (x_imag|x_real|y_imag|y_real) -- exactly the byte string /info serves
	// as "public_key", which is why it needs no reordering here.
	//
	// It is the DKG's collective key, held by no single party. That is the point
	// of the migration: under the SPLASH beacon one key holder knew every future
	// round's randomness, and under this one nobody below the threshold does.
	DrandEvmnetPubKeyHex = "07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b3820557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b"
)
