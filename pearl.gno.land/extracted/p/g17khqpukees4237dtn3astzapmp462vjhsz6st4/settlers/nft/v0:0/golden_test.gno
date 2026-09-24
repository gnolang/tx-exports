package nft

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"testing"
)

// goldenCase is the output of the reference implementation (Appendix A of the spec).
type goldenCase struct {
	seed    string // only for cases created from a seed
	traits  Traits
	packed  uint32
	svgLen  int
	gridSHA string
	svgSHA  string
}

// specSeeds are the seeds of the test vectors of the spec (section 10).
var specSeeds = []struct {
	seed   string
	digest string // first 11 bytes of SHA-256(seed), in hex
}{
	{"alice", "2bd806c97f0e00af1a1fc3"},
	{"bob", "81b637d8fcd2c6da6359e6"},
	{"gnome-0", "95683126dc6336a7a031d6"},
	{"gnome-2", "36523813a082d7384fc3a2"},
	{"gnome-3", "9d16dc6adf068ceaff3684"},
	{"gnome-5", "036a41f7212a1f00d02fb5"},
	{"gnome-38", "0d73c460e4aef1a0e0079c"},
}

// goldenSeeds are cases derived from a seed, the first ones are the seeds of the spec.
var goldenSeeds = []goldenCase{
	{"alice", Traits{Skin: 1, Hat: 1, BeardColor: 2, Tunic: 1, Background: 2, HatShape: 1, Flip: 0, Glasses: 0, Beard: 1}, 272581, 3671, "bc60deccf0c9cd38b51db9fb78afe945fad9e95389fd461e8eb27a30f499722e", "c0eadebb122e1348307a80f94c964237d2b570dc1fac6cd7acad35f3810f163a"},
	{"bob", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 1, Background: 2, HatShape: 0, Flip: 0, Glasses: 0, Beard: 3}, 788712, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "3404ff0484fdd11af347f109ef9e02b7502fc062969f978d5f6b97b147c8b1e0"},
	{"gnome-0", Traits{Skin: 2, Hat: 4, BeardColor: 1, Tunic: 3, Background: 0, HatShape: 0, Flip: 0, Glasses: 0, Beard: 2}, 524722, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "23974d7d35b8ee9ce70288eec42f3166a54a05e49b6b160ad0097f3983b4776e"},
	{"gnome-2", Traits{Skin: 0, Hat: 2, BeardColor: 0, Tunic: 4, Background: 0, HatShape: 0, Flip: 1, Glasses: 4, Beard: 1}, 410120, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "e4937fd7091e8db543619f62cc6f22e26a31296ba30b3b128a2e79304dd741a2"},
	{"gnome-3", Traits{Skin: 1, Hat: 2, BeardColor: 0, Tunic: 1, Background: 3, HatShape: 1, Flip: 0, Glasses: 0, Beard: 1}, 273545, 3671, "bc60deccf0c9cd38b51db9fb78afe945fad9e95389fd461e8eb27a30f499722e", "9e1f8715eec4e7bd84460bd02dce602e23c8d6a543c9218366a1f7b3fe96dc9f"},
	{"gnome-5", Traits{Skin: 0, Hat: 1, BeardColor: 1, Tunic: 2, Background: 3, HatShape: 1, Flip: 1, Glasses: 1, Beard: 2}, 584996, 3619, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "a86e3764d5f5e2728073b1c536029be555562cce5a779fcb3c844faf11b0d2c8"},
	{"gnome-38", Traits{Skin: 1, Hat: 0, BeardColor: 0, Tunic: 1, Background: 3, HatShape: 0, Flip: 1, Glasses: 0, Beard: 0}, 19585, 2794, "35eca8f2fa3bd21d57eb89d0c494a4c5aa53a12b9700f36b61190df7e205e3c2", "db5482795f7a9ce8152020ab1b17567fae2bec7bea7e27d058d852b7e019215f"},
	{"gnome-100", Traits{Skin: 0, Hat: 1, BeardColor: 3, Tunic: 2, Background: 1, HatShape: 0, Flip: 1, Glasses: 0, Beard: 1}, 279908, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "07dc1ae4ab7dddc1e84d1f62e7e7a9b90a8497abc3fb9c661468caffadca286c"},
	{"gnome-101", Traits{Skin: 0, Hat: 4, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 1, Flip: 1, Glasses: 1, Beard: 2}, 583952, 3619, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "a6757043f2992f0f3852741d467bf2e2b275c234df0f1fc3489d43a5ce6832d9"},
	{"gnome-102", Traits{Skin: 1, Hat: 4, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 0, Beard: 1}, 263377, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "8c3b2bc46c90cff722ba4a0d5f210e51259cc8b04efd8f7a584f9571f518d9a5"},
	{"gnome-103", Traits{Skin: 1, Hat: 0, BeardColor: 0, Tunic: 2, Background: 0, HatShape: 0, Flip: 0, Glasses: 1, Beard: 1}, 295169, 3568, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "4874e3316c4225700aecd6f65ec6807ef669380f87d73e318de0861fd38c7cb9"},
	{"gnome-104", Traits{Skin: 0, Hat: 4, BeardColor: 1, Tunic: 2, Background: 4, HatShape: 1, Flip: 0, Glasses: 1, Beard: 1}, 307504, 3699, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "1c7de3bf2ba4cc15ab4f74388c8f545f14f005523b1fee1228f4eae64110dd1e"},
	{"gnome-105", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 1, Background: 4, HatShape: 1, Flip: 1, Glasses: 0, Beard: 2}, 553192, 3591, "05d24de04920aace4b06d16bf9534226c6c215d27339956e463dc8da41d7918d", "c61d0be7800e42707fe69d77dfcebae80b7afbd6008783e5457060289b473c3f"},
	{"gnome-106", Traits{Skin: 0, Hat: 1, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 0, Beard: 3}, 791108, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "1c82b512174d0704699fe68baf605efc6e63c45dad3834a0411446d8f1143ffa"},
	{"gnome-107", Traits{Skin: 2, Hat: 4, BeardColor: 3, Tunic: 2, Background: 3, HatShape: 1, Flip: 0, Glasses: 0, Beard: 1}, 273778, 3671, "bc60deccf0c9cd38b51db9fb78afe945fad9e95389fd461e8eb27a30f499722e", "5f8fdd3f970b5b62b4b535377dc53a11b0b3b1848655537089b39266962e15a6"},
	{"gnome-108", Traits{Skin: 2, Hat: 1, BeardColor: 1, Tunic: 2, Background: 1, HatShape: 0, Flip: 1, Glasses: 0, Beard: 2}, 541990, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "bfe15a015356c052323a5ae37fe3910c902cbcf46cb198f5549129cae02759ff"},
	{"gnome-109", Traits{Skin: 0, Hat: 1, BeardColor: 0, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 4, Beard: 1}, 394372, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "1832191b41a51b7410058fef9cc53cf439df53fcbde2254221326ac59de616d5"},
	{"gnome-110", Traits{Skin: 1, Hat: 1, BeardColor: 3, Tunic: 4, Background: 0, HatShape: 1, Flip: 1, Glasses: 0, Beard: 0}, 25189, 2929, "78062147dbe5c19e7e0da087edeb98296cd9ef02463fc972beccf435d433e79f", "a4a3202c3a7395c62b5643cc579c1a37121645f00f96a91157b410fabf024d6f"},
	{"gnome-111", Traits{Skin: 2, Hat: 4, BeardColor: 2, Tunic: 4, Background: 3, HatShape: 0, Flip: 1, Glasses: 0, Beard: 3}, 806482, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "2eded8349d5ae8e31bc12647579e66dfe9951bbed0a22db37d8b6f95935ff813"},
	{"gnome-112", Traits{Skin: 2, Hat: 1, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 0, Flip: 0, Glasses: 0, Beard: 1}, 264454, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "e407a832c1f93aa61f0627cfe8ba778438d5c05d703a26e41bcb9e177a654b53"},
	{"gnome-113", Traits{Skin: 2, Hat: 0, BeardColor: 1, Tunic: 2, Background: 0, HatShape: 0, Flip: 1, Glasses: 0, Beard: 3}, 803106, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "6c47aa7bfe087aad98770fbb4b3f4b9b78ef2a0af2d19ab7bc266a0ac87bd93d"},
	{"gnome-114", Traits{Skin: 1, Hat: 2, BeardColor: 1, Tunic: 4, Background: 0, HatShape: 1, Flip: 1, Glasses: 0, Beard: 2}, 549417, 3591, "05d24de04920aace4b06d16bf9534226c6c215d27339956e463dc8da41d7918d", "e7aac193af67a86291c3738eb6d3783da5d229feb8c1be2a32fd4500a9e24e78"},
	{"gnome-115", Traits{Skin: 0, Hat: 1, BeardColor: 0, Tunic: 4, Background: 0, HatShape: 0, Flip: 0, Glasses: 0, Beard: 2}, 524804, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "518228e8f82c0e1b1b758fc20334cbc864cb61f484bc16044cf7b813aa027f30"},
	{"gnome-116", Traits{Skin: 2, Hat: 4, BeardColor: 3, Tunic: 3, Background: 2, HatShape: 1, Flip: 0, Glasses: 3, Beard: 1}, 371186, 3726, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "0d4ef73473df5554f4efab5c035939b1ede4850fc40f9ea9da1a15f06c699a96"},
	{"gnome-117", Traits{Skin: 1, Hat: 2, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 0, Flip: 1, Glasses: 0, Beard: 3}, 804041, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "363f90dbef379a37217c152472428960979b94935774503838c9a3d6e74bc842"},
	{"gnome-118", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 2, Background: 1, HatShape: 0, Flip: 1, Glasses: 2, Beard: 1}, 345448, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "0a1b170ffebedfa4f8dd816fec32854f5117af998b55d01dc8971e76957c02b8"},
	{"gnome-119", Traits{Skin: 2, Hat: 4, BeardColor: 2, Tunic: 3, Background: 1, HatShape: 1, Flip: 0, Glasses: 0, Beard: 3}, 796114, 3292, "4b81c396473bb3f81f5c3d1f50af7088491fb67de7df7d4ea885905b2e2773d8", "9e33ba8e0fa995c817fe3c097bebee91c857047b7c6dd8b8a765c3aa9a553795"},
	{"gnome-120", Traits{Skin: 2, Hat: 0, BeardColor: 0, Tunic: 2, Background: 1, HatShape: 0, Flip: 1, Glasses: 1, Beard: 2}, 574722, 3484, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "d9d14194203391b5eeec463fecd2e482093ae88f7b9643467fce14001e668afc"},
	{"gnome-121", Traits{Skin: 1, Hat: 2, BeardColor: 2, Tunic: 1, Background: 4, HatShape: 0, Flip: 1, Glasses: 0, Beard: 3}, 807113, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "2fa5fd25208299abfb835ebc446ca942936ea1c1c80e7579dadbd21bd9825ea2"},
	{"gnome-122", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 2, Background: 0, HatShape: 0, Flip: 1, Glasses: 0, Beard: 2}, 541032, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "2d9541b55c10c8eaa6dbebae39a84c40a06a4d6033407a25dcc2058f2aa6e317"},
	{"gnome-123", Traits{Skin: 2, Hat: 1, BeardColor: 3, Tunic: 3, Background: 3, HatShape: 0, Flip: 0, Glasses: 0, Beard: 1}, 265702, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "c1b91c36260e44f4c4cb87afeccbacb0c3d131fbc14dc0c08287f048008e4df3"},
	{"gnome-124", Traits{Skin: 0, Hat: 1, BeardColor: 2, Tunic: 0, Background: 3, HatShape: 1, Flip: 1, Glasses: 0, Beard: 1}, 289860, 3675, "2d220e36e6b18cb2fc294e333c52dc23661947f58101bed0bad3f6eb07a3f6da", "21610576923352aae0c96523f28cb155f617d988e04e886a7f13bb04b6f76f37"},
	{"gnome-125", Traits{Skin: 2, Hat: 3, BeardColor: 1, Tunic: 0, Background: 0, HatShape: 1, Flip: 1, Glasses: 0, Beard: 3}, 811054, 3296, "3a0eeaa78cabd9e6d6e91543065b208421805c65e0f6ea6494fd8047e8488623", "93a3b8826894b7e6b7097cd2bfe64d5263d0bec854c68a1135d83559dc590502"},
	{"gnome-126", Traits{Skin: 0, Hat: 4, BeardColor: 3, Tunic: 0, Background: 4, HatShape: 0, Flip: 0, Glasses: 3, Beard: 1}, 364656, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "1b43ea8c4c2431e054f692a210824de8a4eba16a7dfefd7143142df11ba2e85c"},
	{"gnome-127", Traits{Skin: 1, Hat: 1, BeardColor: 0, Tunic: 0, Background: 0, HatShape: 0, Flip: 1, Glasses: 3, Beard: 1}, 376837, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "7d7f22c65024db3b9b3530aaa8b1daddc9c6d6c4fcebd38cac6dedd90824ebbe"},
	{"gnome-128", Traits{Skin: 1, Hat: 1, BeardColor: 3, Tunic: 4, Background: 0, HatShape: 0, Flip: 0, Glasses: 0, Beard: 3}, 787045, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "7ea09e90ec7748485e3a2a4d63ca7e1569823002aea7b656bb8859cd98ea9ea3"},
	{"gnome-129", Traits{Skin: 2, Hat: 3, BeardColor: 3, Tunic: 2, Background: 4, HatShape: 1, Flip: 0, Glasses: 3, Beard: 2}, 635246, 3642, "21991c0335313c9a5ce8364b4e434ed1be6ad9732519a4129e014395cee261d7", "5958d80eed2f37e65af4463a7b0764baa3520fcfc0814910aa08a6bd107099fc"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 0, Tunic: 1, Background: 2, HatShape: 0, Flip: 0, Glasses: 3, Beard: 2}, 624774, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "670ac428173c63dcc6f220acf0e12f481a7ae4f89b516173061707faf7b73ad7"},
	{"Gnome", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 3, Beard: 3}, 889448, 3216, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "03a4be3be69ccf875aa79973e6a5566bb515adff5ed80956f85185cc09174f30"},
	{"gnome-0 ", Traits{Skin: 1, Hat: 0, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 0, Beard: 3}, 815681, 3296, "3a0eeaa78cabd9e6d6e91543065b208421805c65e0f6ea6494fd8047e8488623", "2db3a310e9b678acff97c427f541374a8774fffa219e785921e3b3d2b9277761"},
	{"ñandú", Traits{Skin: 1, Hat: 4, BeardColor: 2, Tunic: 1, Background: 3, HatShape: 1, Flip: 0, Glasses: 0, Beard: 2}, 535761, 3587, "b9abd381f7541eb5ba89663f6a455b501d714c3b7af83b8430a18431732d89ce", "fef1a5c2840dcb71755b323c06c76246d048b68ecbdea1e9c107fffd56349198"},
	{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Traits{Skin: 1, Hat: 2, BeardColor: 1, Tunic: 0, Background: 1, HatShape: 0, Flip: 0, Glasses: 0, Beard: 2}, 525353, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "fb2042a1d693f5d9b9da0cb91b561d4fdb372af5ed627546d912de0e1e06f35f"},
}

// goldenTraits are cases created from traits, that cover the hat, glasses and beard combinations.
var goldenTraits = []goldenCase{
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 0, Tunic: 0, Background: 0, HatShape: 0, Flip: 0, Glasses: 0, Beard: 0}, 0, 2794, "35eca8f2fa3bd21d57eb89d0c494a4c5aa53a12b9700f36b61190df7e205e3c2", "d4a831eee77f803d5f3de543bd95be9316338352be46ff8d28aa1540d2dfc024"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 1, Tunic: 2, Background: 2, HatShape: 0, Flip: 0, Glasses: 0, Beard: 1}, 264493, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "5f635328009935025b446ad5b5da8a25f9cea9e6eb9bfe5da555bd20e13b65f0"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 0, Beard: 2}, 528966, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "aa36a10124d66b39dc7607eb035dfa2ae4a2b73c1ee4eef039ebcc256a1c7baa"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 3, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 0, Beard: 3}, 787696, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "6f1b9eb0c0288b8ef82c3c072a6000ff228f1ee839a54809067ad092b1c54f96"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 0, Tunic: 3, Background: 3, HatShape: 0, Flip: 0, Glasses: 1, Beard: 0}, 36233, 2822, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "4fb4bea69d3ca1996075530749015150a7137bdbd1e6c9f590cc7243ea1b881a"},
	{"", Traits{Skin: 2, Hat: 0, BeardColor: 1, Tunic: 0, Background: 0, HatShape: 0, Flip: 0, Glasses: 1, Beard: 1}, 294946, 3568, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "bfb6a5765c842b00ac950a3ac8c242530ed5609fb6b972962834e272de4f46d7"},
	{"", Traits{Skin: 0, Hat: 3, BeardColor: 2, Tunic: 2, Background: 2, HatShape: 0, Flip: 0, Glasses: 1, Beard: 2}, 559436, 3484, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "e7dc571c576594fefb785e17c3d2e393ed1b6f99cd1c9bab6bf7a782dac7245d"},
	{"", Traits{Skin: 1, Hat: 1, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 1, Beard: 3}, 823909, 3189, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "a4458727b2d6c14d484f88c484e91f1171ac9f2bb133f894b42f98854bfcdc7b"},
	{"", Traits{Skin: 2, Hat: 4, BeardColor: 0, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 2, Beard: 0}, 66706, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "95bc4e4a498f5e62bd10b39333dae50be8e85d52515ef20e699481930793150d"},
	{"", Traits{Skin: 0, Hat: 2, BeardColor: 1, Tunic: 3, Background: 3, HatShape: 0, Flip: 0, Glasses: 2, Beard: 1}, 331176, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "137e7d2febbf54519e0afc42f6d0fd779e85d3e84f2f729d0eb74e3db758c6ed"},
	{"", Traits{Skin: 1, Hat: 0, BeardColor: 2, Tunic: 0, Background: 0, HatShape: 0, Flip: 0, Glasses: 2, Beard: 2}, 589889, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "982938d32b4764601801f9022599f0ee6fe015aef30d5c826ea644e63a861f41"},
	{"", Traits{Skin: 2, Hat: 3, BeardColor: 3, Tunic: 2, Background: 2, HatShape: 0, Flip: 0, Glasses: 2, Beard: 3}, 854382, 3216, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "9ba263ce748d58dde793736359a76cba5bcd6e593249b6f36e609e08bd3b8b78"},
	{"", Traits{Skin: 0, Hat: 1, BeardColor: 0, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 3, Beard: 0}, 102916, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "01d2ea0d036928be7f05d90587026f6c507f932386011f04b1165f87ae90ae4f"},
	{"", Traits{Skin: 1, Hat: 4, BeardColor: 1, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 3, Beard: 1}, 361649, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "c60f01e84082a736d842370cbf2d421029b0c54ffaf7fc48692c097bfb9c141e"},
	{"", Traits{Skin: 2, Hat: 2, BeardColor: 2, Tunic: 3, Background: 3, HatShape: 0, Flip: 0, Glasses: 3, Beard: 2}, 626122, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "5bd0dcfa582bdf727eb13489f689dfe4f8873659831eae3f90c1be8aac52929c"},
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 3, Tunic: 0, Background: 0, HatShape: 0, Flip: 0, Glasses: 3, Beard: 3}, 884832, 3189, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "0b8a1a888cc74dc5a87f0ea95a8b8ee4f771ee977e3df88378c44ca97faaa9e1"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 0, Flip: 0, Glasses: 4, Beard: 0}, 133389, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "ac2000f554e5ff8a22f4738ac475a165b95f56df7c3f23c583e07b41fe4b28e3"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 1, Tunic: 4, Background: 4, HatShape: 0, Flip: 0, Glasses: 4, Beard: 1}, 397862, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "c8b15012a5c30ed5a20ef67ae209f2573d08b8dfefebb580b01f616ea5164001"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 0, Flip: 0, Glasses: 4, Beard: 2}, 656592, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "54e8ac1f64f48de121035372b3bd20a420727818b8cfc6c4c7b6ecca06db6f55"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 3, Background: 3, HatShape: 0, Flip: 0, Glasses: 4, Beard: 3}, 921065, 3216, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "3b4e9777060691c7741320067619711757ec8ceb869e7a595d8580251cc04e01"},
	{"", Traits{Skin: 2, Hat: 0, BeardColor: 0, Tunic: 0, Background: 0, HatShape: 1, Flip: 0, Glasses: 0, Beard: 0}, 8194, 2925, "b75cd45a00cf48ed7277db1e80cf11c82cac0f37ee05f305d558c4b22c24b0d8", "138e392f4d17bdec4947c1b461ae82926a3b670bcf9b011552f2cb4390eddd1a"},
	{"", Traits{Skin: 0, Hat: 3, BeardColor: 1, Tunic: 2, Background: 2, HatShape: 1, Flip: 0, Glasses: 0, Beard: 1}, 272684, 3671, "bc60deccf0c9cd38b51db9fb78afe945fad9e95389fd461e8eb27a30f499722e", "386c126167ceeefc42bea425b70b5123bb8de4e0485b155678d6ea314b66b1bd"},
	{"", Traits{Skin: 1, Hat: 1, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 1, Flip: 0, Glasses: 0, Beard: 2}, 537157, 3587, "b9abd381f7541eb5ba89663f6a455b501d714c3b7af83b8430a18431732d89ce", "4294e42718c45e8360be390a13de0f91fb376dd96729ea0d149de7c4f41a5a1d"},
	{"", Traits{Skin: 2, Hat: 4, BeardColor: 3, Tunic: 1, Background: 1, HatShape: 1, Flip: 0, Glasses: 0, Beard: 3}, 795890, 3292, "4b81c396473bb3f81f5c3d1f50af7088491fb67de7df7d4ea885905b2e2773d8", "a891a05ea2bfe696661e13782b6cc8bb4c4bb6c5aca2c0729b538adcdaab5c41"},
	{"", Traits{Skin: 0, Hat: 2, BeardColor: 0, Tunic: 3, Background: 3, HatShape: 1, Flip: 0, Glasses: 1, Beard: 0}, 44424, 2953, "4099824a4957a3779980a322f1d0d05dd6eb5a220e7af73a1e9a293ff98f21e8", "88896cd161139a236295330a34c33172a52e9d65b880627feb53b05599e7d848"},
	{"", Traits{Skin: 1, Hat: 0, BeardColor: 1, Tunic: 0, Background: 0, HatShape: 1, Flip: 0, Glasses: 1, Beard: 1}, 303137, 3699, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "5eac04dc3fb0ec9ec02b6a59ade9e14462f93d854371fee239efc24920d90558"},
	{"", Traits{Skin: 2, Hat: 3, BeardColor: 2, Tunic: 2, Background: 2, HatShape: 1, Flip: 0, Glasses: 1, Beard: 2}, 567630, 3615, "21991c0335313c9a5ce8364b4e434ed1be6ad9732519a4129e014395cee261d7", "5717a1dfc3be46ab1ee780cd954543223d1c109414c700699d0aa4c6260e6518"},
	{"", Traits{Skin: 0, Hat: 1, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 1, Flip: 0, Glasses: 1, Beard: 3}, 832100, 3320, "854c4e229b54764e891b46b5033172bec96eb18100ec54c8f0835bfeb4acd8de", "582b6bd2b90221262436169e9768c9b53b13ba5aadc63a53f2d48c43e4ad04c6"},
	{"", Traits{Skin: 1, Hat: 4, BeardColor: 0, Tunic: 1, Background: 1, HatShape: 1, Flip: 0, Glasses: 2, Beard: 0}, 74897, 2980, "4099824a4957a3779980a322f1d0d05dd6eb5a220e7af73a1e9a293ff98f21e8", "064a268488d18e255ad92108d9a7d101496d3469a228f0ab6ac5f6b03641dddf"},
	{"", Traits{Skin: 2, Hat: 2, BeardColor: 1, Tunic: 3, Background: 3, HatShape: 1, Flip: 0, Glasses: 2, Beard: 1}, 339370, 3726, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "22cd29dc024ccf4cf02e4060a9b71f25dc09777b5e58911f37fba6ebfb4cde8e"},
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 2, Tunic: 0, Background: 0, HatShape: 1, Flip: 0, Glasses: 2, Beard: 2}, 598080, 3642, "21991c0335313c9a5ce8364b4e434ed1be6ad9732519a4129e014395cee261d7", "60c3471554cfd250aa52c4cf428ab5378b350dcf11440509ebd01ae69ad0f7bd"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 3, Tunic: 2, Background: 2, HatShape: 1, Flip: 0, Glasses: 2, Beard: 3}, 862573, 3347, "854c4e229b54764e891b46b5033172bec96eb18100ec54c8f0835bfeb4acd8de", "2d849331438d83af5c336369f3b5d487434c01d417387c0db2436ac27efd34d0"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 0, Tunic: 4, Background: 4, HatShape: 1, Flip: 0, Glasses: 3, Beard: 0}, 111110, 2980, "4099824a4957a3779980a322f1d0d05dd6eb5a220e7af73a1e9a293ff98f21e8", "587792f3d658f4c65f347b42dc4210d620b6e41b5aeaeb7318a481dec2d8a776"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 1, Tunic: 1, Background: 1, HatShape: 1, Flip: 0, Glasses: 3, Beard: 1}, 369840, 3726, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "1b2b08eaf01f06ace18bc94939c1a2d34b1632bcaa524c3c4171a038e8ebd57d"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 2, Tunic: 3, Background: 3, HatShape: 1, Flip: 0, Glasses: 3, Beard: 2}, 634313, 3642, "21991c0335313c9a5ce8364b4e434ed1be6ad9732519a4129e014395cee261d7", "e910d0b6f0f0b1430b9a959c8fdacb1cde58b8e0d89cd5b786b8e0dbc96361bf"},
	{"", Traits{Skin: 2, Hat: 0, BeardColor: 3, Tunic: 0, Background: 0, HatShape: 1, Flip: 0, Glasses: 3, Beard: 3}, 893026, 3320, "854c4e229b54764e891b46b5033172bec96eb18100ec54c8f0835bfeb4acd8de", "5d87d7391f59f867319b97b73b5ea90fa139091c6f5598172af1b0f5d7553b63"},
	{"", Traits{Skin: 0, Hat: 3, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 1, Flip: 0, Glasses: 4, Beard: 0}, 141580, 2980, "4099824a4957a3779980a322f1d0d05dd6eb5a220e7af73a1e9a293ff98f21e8", "3c03ce1f39d79b10fb3dbb4f66e30d11653b2983f68c4ac32c91407f91ae24bf"},
	{"", Traits{Skin: 1, Hat: 1, BeardColor: 1, Tunic: 4, Background: 4, HatShape: 1, Flip: 0, Glasses: 4, Beard: 1}, 406053, 3726, "b120a6ec57c967129c090e7f8c37ebdba98978992e638848038380d73a450887", "139acdaac52ff21c42059a47727fd21664d3a8dfa1041eb8398259bd2e440207"},
	{"", Traits{Skin: 2, Hat: 4, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 1, Flip: 0, Glasses: 4, Beard: 2}, 664786, 3642, "21991c0335313c9a5ce8364b4e434ed1be6ad9732519a4129e014395cee261d7", "e1b5786be4c8de8f768111b27e3f8dee3071629733582b6b9a348a51ce184c92"},
	{"", Traits{Skin: 0, Hat: 2, BeardColor: 3, Tunic: 3, Background: 3, HatShape: 1, Flip: 0, Glasses: 4, Beard: 3}, 929256, 3347, "854c4e229b54764e891b46b5033172bec96eb18100ec54c8f0835bfeb4acd8de", "4af64c7f38201c08414a8dc2e7a93f530468de915ac8c94b7457caf949f36eb2"},
	{"", Traits{Skin: 1, Hat: 0, BeardColor: 0, Tunic: 0, Background: 0, HatShape: 1, Flip: 1, Glasses: 0, Beard: 0}, 24577, 2929, "78062147dbe5c19e7e0da087edeb98296cd9ef02463fc972beccf435d433e79f", "67f18f08a9b1fe351b2364d6a6552ca84c65513701073951d06617ed51f199cb"},
	{"", Traits{Skin: 2, Hat: 3, BeardColor: 1, Tunic: 2, Background: 2, HatShape: 1, Flip: 1, Glasses: 0, Beard: 1}, 289070, 3675, "2d220e36e6b18cb2fc294e333c52dc23661947f58101bed0bad3f6eb07a3f6da", "62490d532b1f1e606224ce0c9526570907a036608c8539281830fbca72592197"},
	{"", Traits{Skin: 0, Hat: 1, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 0, Beard: 2}, 553540, 3591, "05d24de04920aace4b06d16bf9534226c6c215d27339956e463dc8da41d7918d", "ad648015d864964228e008625e93967e6a448251822af9dfa8b8f03550b9f6b6"},
	{"", Traits{Skin: 1, Hat: 4, BeardColor: 3, Tunic: 1, Background: 1, HatShape: 1, Flip: 1, Glasses: 0, Beard: 3}, 812273, 3296, "3a0eeaa78cabd9e6d6e91543065b208421805c65e0f6ea6494fd8047e8488623", "338cdef8bd32644ecea0a2160d9e7909e42222278ce76bbd0c527a76e245a234"},
	{"", Traits{Skin: 2, Hat: 2, BeardColor: 0, Tunic: 3, Background: 3, HatShape: 1, Flip: 1, Glasses: 1, Beard: 0}, 60810, 2957, "bc407488cddc05be0b5426d5c282ca8e4581d6a1204f1402612a2346e8b364ef", "c223c83a41b386ff26b7119d82472e64d9c1005ebc83d7fac610b53fe931442e"},
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 1, Tunic: 0, Background: 0, HatShape: 1, Flip: 1, Glasses: 1, Beard: 1}, 319520, 3703, "5d21ca2eede47a37ccf4fa3464363d9baea18072dec11d8867512141517bd756", "2af26256f96f0491ead1f3da86d4c728c96f429eff21aef9631fd6e2ceac3e0c"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 2, Tunic: 2, Background: 2, HatShape: 1, Flip: 1, Glasses: 1, Beard: 2}, 584013, 3619, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "ff16e76a343573bfaa6ed93917f2f9362b9de488b1a6fd5ac45880e4bfa2cc40"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 1, Beard: 3}, 848486, 3324, "7ba8d753f9c16c7503fd0b91bfd4ab14bd62f64898a4a86eb318f4847c08a6c0", "0a22ed2ed72df8b3bc979807c425311a6012a347902b02048935ae05cefc7a12"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 0, Tunic: 1, Background: 1, HatShape: 1, Flip: 1, Glasses: 2, Beard: 0}, 91280, 2984, "bc407488cddc05be0b5426d5c282ca8e4581d6a1204f1402612a2346e8b364ef", "e88cc38e6c3cf8ca0354bca530203955265cbdab07e0f1633de226b7d25f3e65"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 1, Tunic: 3, Background: 3, HatShape: 1, Flip: 1, Glasses: 2, Beard: 1}, 355753, 3730, "5d21ca2eede47a37ccf4fa3464363d9baea18072dec11d8867512141517bd756", "4cc2510131335811b2543f6868ca1f85cbd806949d2490abdd2d77dae0113479"},
	{"", Traits{Skin: 2, Hat: 0, BeardColor: 2, Tunic: 0, Background: 0, HatShape: 1, Flip: 1, Glasses: 2, Beard: 2}, 614466, 3646, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "28f7769356f2839ccd50bae4ada296a24ade811bb9be23796e0cf6a269d322ec"},
	{"", Traits{Skin: 0, Hat: 3, BeardColor: 3, Tunic: 2, Background: 2, HatShape: 1, Flip: 1, Glasses: 2, Beard: 3}, 878956, 3351, "7ba8d753f9c16c7503fd0b91bfd4ab14bd62f64898a4a86eb318f4847c08a6c0", "d39b2f80cb0b07d121740163d36a527fe131da4ad1a438c8b2be68bf21200cbf"},
	{"", Traits{Skin: 1, Hat: 1, BeardColor: 0, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 3, Beard: 0}, 127493, 2984, "bc407488cddc05be0b5426d5c282ca8e4581d6a1204f1402612a2346e8b364ef", "74288be18fe4965727be9caae2bda10724c04051c60ff4db7d7ddd8796c82839"},
	{"", Traits{Skin: 2, Hat: 4, BeardColor: 1, Tunic: 1, Background: 1, HatShape: 1, Flip: 1, Glasses: 3, Beard: 1}, 386226, 3730, "5d21ca2eede47a37ccf4fa3464363d9baea18072dec11d8867512141517bd756", "fa5996a9a05f839dcf7481e7e1bc70d522291cfa49f09bd1ab17348ec3ed7dc5"},
	{"", Traits{Skin: 0, Hat: 2, BeardColor: 2, Tunic: 3, Background: 3, HatShape: 1, Flip: 1, Glasses: 3, Beard: 2}, 650696, 3646, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "836c705f6290c16320cded0dd7a8e1463b15aadd5cd4f447d0e4d4754ae1902e"},
	{"", Traits{Skin: 1, Hat: 0, BeardColor: 3, Tunic: 0, Background: 0, HatShape: 1, Flip: 1, Glasses: 3, Beard: 3}, 909409, 3324, "7ba8d753f9c16c7503fd0b91bfd4ab14bd62f64898a4a86eb318f4847c08a6c0", "6662ee74f2100540573532db90a6b9e0eaa0c381c5bb5f8319192f00a5a30ed7"},
	{"", Traits{Skin: 2, Hat: 3, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 1, Flip: 1, Glasses: 4, Beard: 0}, 157966, 2984, "bc407488cddc05be0b5426d5c282ca8e4581d6a1204f1402612a2346e8b364ef", "4f5dd9811d9060712c18d0f44e1b86fac0b8adc16e21e663f2d57d7191c7fa93"},
	{"", Traits{Skin: 0, Hat: 1, BeardColor: 1, Tunic: 4, Background: 4, HatShape: 1, Flip: 1, Glasses: 4, Beard: 1}, 422436, 3730, "5d21ca2eede47a37ccf4fa3464363d9baea18072dec11d8867512141517bd756", "aff9b27f75e94fabc3cfda9c349554552f0b3e93276c5893f4e26b41c22fb7c5"},
	{"", Traits{Skin: 1, Hat: 4, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 1, Flip: 1, Glasses: 4, Beard: 2}, 681169, 3646, "2ecfd8163ceeeb476d0465a71bf00b86fb1ef4215936c01c3655297cffa55620", "5c3e0db49d9f54c7a46f8f6fee2716958fd2efa533490e07f17678c31834b701"},
	{"", Traits{Skin: 2, Hat: 2, BeardColor: 3, Tunic: 3, Background: 3, HatShape: 1, Flip: 1, Glasses: 4, Beard: 3}, 945642, 3351, "7ba8d753f9c16c7503fd0b91bfd4ab14bd62f64898a4a86eb318f4847c08a6c0", "0c0e747b14232addfcccf8132219a8b58d094d6e3fe7a155e4bcd54714fe60de"},
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 0, Tunic: 0, Background: 0, HatShape: 0, Flip: 1, Glasses: 0, Beard: 0}, 16384, 2794, "35eca8f2fa3bd21d57eb89d0c494a4c5aa53a12b9700f36b61190df7e205e3c2", "d4a831eee77f803d5f3de543bd95be9316338352be46ff8d28aa1540d2dfc024"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 1, Tunic: 2, Background: 2, HatShape: 0, Flip: 1, Glasses: 0, Beard: 1}, 280877, 3540, "0f3bd3b782e0b46443eeb7ba19dcdff814b9063ebd71e1989e70b5875eacd6ff", "5f635328009935025b446ad5b5da8a25f9cea9e6eb9bfe5da555bd20e13b65f0"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 2, Tunic: 4, Background: 4, HatShape: 0, Flip: 1, Glasses: 0, Beard: 2}, 545350, 3456, "2b499f3970d0aeff488b54a71c472c86f8633a352f251a4fb54c8961dc991549", "aa36a10124d66b39dc7607eb035dfa2ae4a2b73c1ee4eef039ebcc256a1c7baa"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 3, Tunic: 1, Background: 1, HatShape: 0, Flip: 1, Glasses: 0, Beard: 3}, 804080, 3161, "e27277da08aaf28293c8725bdd6c834e500a432d78f8e7f6baeb8d5d1cf74019", "6f1b9eb0c0288b8ef82c3c072a6000ff228f1ee839a54809067ad092b1c54f96"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 0, Tunic: 3, Background: 3, HatShape: 0, Flip: 1, Glasses: 1, Beard: 0}, 52617, 2822, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "4fb4bea69d3ca1996075530749015150a7137bdbd1e6c9f590cc7243ea1b881a"},
	{"", Traits{Skin: 2, Hat: 0, BeardColor: 1, Tunic: 0, Background: 0, HatShape: 0, Flip: 1, Glasses: 1, Beard: 1}, 311330, 3568, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "bfb6a5765c842b00ac950a3ac8c242530ed5609fb6b972962834e272de4f46d7"},
	{"", Traits{Skin: 0, Hat: 3, BeardColor: 2, Tunic: 2, Background: 2, HatShape: 0, Flip: 1, Glasses: 1, Beard: 2}, 575820, 3484, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "e7dc571c576594fefb785e17c3d2e393ed1b6f99cd1c9bab6bf7a782dac7245d"},
	{"", Traits{Skin: 1, Hat: 1, BeardColor: 3, Tunic: 4, Background: 4, HatShape: 0, Flip: 1, Glasses: 1, Beard: 3}, 840293, 3189, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "a4458727b2d6c14d484f88c484e91f1171ac9f2bb133f894b42f98854bfcdc7b"},
	{"", Traits{Skin: 2, Hat: 4, BeardColor: 0, Tunic: 1, Background: 1, HatShape: 0, Flip: 1, Glasses: 2, Beard: 0}, 83090, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "95bc4e4a498f5e62bd10b39333dae50be8e85d52515ef20e699481930793150d"},
	{"", Traits{Skin: 0, Hat: 2, BeardColor: 1, Tunic: 3, Background: 3, HatShape: 0, Flip: 1, Glasses: 2, Beard: 1}, 347560, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "137e7d2febbf54519e0afc42f6d0fd779e85d3e84f2f729d0eb74e3db758c6ed"},
	{"", Traits{Skin: 1, Hat: 0, BeardColor: 2, Tunic: 0, Background: 0, HatShape: 0, Flip: 1, Glasses: 2, Beard: 2}, 606273, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "982938d32b4764601801f9022599f0ee6fe015aef30d5c826ea644e63a861f41"},
	{"", Traits{Skin: 2, Hat: 3, BeardColor: 3, Tunic: 2, Background: 2, HatShape: 0, Flip: 1, Glasses: 2, Beard: 3}, 870766, 3216, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "9ba263ce748d58dde793736359a76cba5bcd6e593249b6f36e609e08bd3b8b78"},
	{"", Traits{Skin: 0, Hat: 1, BeardColor: 0, Tunic: 4, Background: 4, HatShape: 0, Flip: 1, Glasses: 3, Beard: 0}, 119300, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "01d2ea0d036928be7f05d90587026f6c507f932386011f04b1165f87ae90ae4f"},
	{"", Traits{Skin: 1, Hat: 4, BeardColor: 1, Tunic: 1, Background: 1, HatShape: 0, Flip: 1, Glasses: 3, Beard: 1}, 378033, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "c60f01e84082a736d842370cbf2d421029b0c54ffaf7fc48692c097bfb9c141e"},
	{"", Traits{Skin: 2, Hat: 2, BeardColor: 2, Tunic: 3, Background: 3, HatShape: 0, Flip: 1, Glasses: 3, Beard: 2}, 642506, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "5bd0dcfa582bdf727eb13489f689dfe4f8873659831eae3f90c1be8aac52929c"},
	{"", Traits{Skin: 0, Hat: 0, BeardColor: 3, Tunic: 0, Background: 0, HatShape: 0, Flip: 1, Glasses: 3, Beard: 3}, 901216, 3189, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "0b8a1a888cc74dc5a87f0ea95a8b8ee4f771ee977e3df88378c44ca97faaa9e1"},
	{"", Traits{Skin: 1, Hat: 3, BeardColor: 0, Tunic: 2, Background: 2, HatShape: 0, Flip: 1, Glasses: 4, Beard: 0}, 149773, 2849, "235234e97f8eb6b65bdeba757e02aceb64aec3512f396beb381c0ab3749153da", "ac2000f554e5ff8a22f4738ac475a165b95f56df7c3f23c583e07b41fe4b28e3"},
	{"", Traits{Skin: 2, Hat: 1, BeardColor: 1, Tunic: 4, Background: 4, HatShape: 0, Flip: 1, Glasses: 4, Beard: 1}, 414246, 3595, "419e28b1b5c9838952993fb28ec813aaf8010d66001943e3f7f2e38f1b84e36c", "c8b15012a5c30ed5a20ef67ae209f2573d08b8dfefebb580b01f616ea5164001"},
	{"", Traits{Skin: 0, Hat: 4, BeardColor: 2, Tunic: 1, Background: 1, HatShape: 0, Flip: 1, Glasses: 4, Beard: 2}, 672976, 3511, "fc62236523239dc5339bd95fa8f3c21685e5399e159b468f1fd4a3fde04e11fd", "54e8ac1f64f48de121035372b3bd20a420727818b8cfc6c4c7b6ecca06db6f55"},
	{"", Traits{Skin: 1, Hat: 2, BeardColor: 3, Tunic: 3, Background: 3, HatShape: 0, Flip: 1, Glasses: 4, Beard: 3}, 937449, 3216, "7cad07ccf6c980f6b3754625f669ba6d3679db3722182cacf9a81b8ce30b538d", "3b4e9777060691c7741320067619711757ec8ceb869e7a595d8580251cc04e01"},
}

// aliceSVG is the full SVG that the spec shows for the seed alice.
const aliceSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 0 32 32" shape-rendering="crispEdges"><rect x="-4" width="32" height="32" fill="#dbeed2"/><path fill="#2a1a2e" d="M11 0h4v1h-4zM10 1h1v1h-1zM15 1h1v1h-1zM10 2h1v1h-1zM13 2h1v1h-1zM16 2h1v1h-1zM10 3h1v1h-1zM13 3h2v1h-2zM16 3h1v1h-1zM9 4h1v1h-1zM14 4h2v1h-2zM9 5h1v1h-1zM14 5h1v1h-1zM8 6h1v1h-1zM15 6h1v1h-1zM8 7h1v1h-1zM15 7h1v1h-1zM7 8h1v1h-1zM16 8h1v1h-1zM7 9h1v1h-1zM16 9h1v1h-1zM6 10h1v1h-1zM17 10h1v1h-1zM4 11h1v1h-1zM19 11h1v1h-1zM4 12h1v1h-1zM19 12h1v1h-1zM6 13h1v1h-1zM17 13h1v1h-1zM6 14h1v1h-1zM17 14h1v1h-1zM5 15h1v1h-1zM18 15h1v1h-1zM4 16h1v1h-1zM19 16h1v1h-1zM6 17h1v1h-1zM17 17h1v1h-1zM5 18h1v1h-1zM18 18h1v1h-1zM4 19h2v1h-2zM18 19h2v1h-2zM3 20h1v1h-1zM5 20h1v1h-1zM18 20h1v1h-1zM20 20h1v1h-1zM3 21h1v1h-1zM6 21h1v1h-1zM17 21h1v1h-1zM20 21h1v1h-1zM3 22h1v1h-1zM6 22h1v1h-1zM17 22h1v1h-1zM20 22h1v1h-1zM2 23h1v1h-1zM7 23h1v1h-1zM16 23h1v1h-1zM21 23h1v1h-1zM2 24h1v1h-1zM7 24h1v1h-1zM16 24h1v1h-1zM21 24h1v1h-1zM3 25h1v1h-1zM8 25h1v1h-1zM15 25h1v1h-1zM20 25h1v1h-1zM3 26h1v1h-1zM9 26h1v1h-1zM14 26h1v1h-1zM20 26h1v1h-1zM3 27h1v1h-1zM10 27h1v1h-1zM13 27h1v1h-1zM20 27h1v1h-1zM5 28h1v1h-1zM11 28h2v1h-2zM18 28h1v1h-1zM5 29h1v1h-1zM11 29h2v1h-2zM18 29h1v1h-1zM5 30h1v1h-1zM11 30h2v1h-2zM18 30h1v1h-1zM5 31h14v1h-14z"/><path fill="#6aa0f0" d="M11 1h1v1h-1zM11 3h1v1h-1zM15 3h1v1h-1zM10 5h1v1h-1zM9 7h1v1h-1zM8 9h1v1h-1zM5 11h1v1h-1z"/><path fill="#3f6fd1" d="M12 1h1v1h-1zM11 2h1v1h-1zM14 2h1v1h-1zM10 4h3v1h-3zM11 5h2v1h-2zM9 6h5v1h-5zM10 7h4v1h-4zM8 8h7v1h-7zM9 9h6v1h-6zM7 10h1v1h-1zM6 11h12v1h-12z"/><path fill="#2b4a99" d="M13 1h2v1h-2zM12 2h1v1h-1zM15 2h1v1h-1zM12 3h1v1h-1zM13 4h1v1h-1zM13 5h1v1h-1zM14 6h1v1h-1zM14 7h1v1h-1zM15 8h1v1h-1zM15 9h1v1h-1zM8 10h9v1h-9zM18 11h1v1h-1zM5 12h14v1h-14z"/><path fill="#b57650" d="M7 13h10v1h-10zM5 16h1v1h-1zM18 16h1v1h-1zM3 24h1v1h-1zM20 24h1v1h-1z"/><path fill="#d99a6c" d="M7 14h1v1h-1zM11 14h2v1h-2zM16 14h1v1h-1zM6 15h2v1h-2zM9 15h6v1h-6zM16 15h2v1h-2zM6 16h2v1h-2zM9 16h2v1h-2zM13 16h2v1h-2zM16 16h2v1h-2zM7 17h3v1h-3zM14 17h3v1h-3zM3 23h1v1h-1zM20 23h1v1h-1z"/><path fill="#e07a2a" d="M8 14h3v1h-3zM13 14h3v1h-3zM7 18h3v1h-3zM14 18h3v1h-3zM7 19h10v1h-10zM7 20h3v1h-3zM11 20h2v1h-2zM14 20h3v1h-3zM8 21h2v1h-2zM11 21h2v1h-2zM14 21h2v1h-2zM8 22h1v1h-1zM10 22h4v1h-4zM15 22h1v1h-1zM9 23h1v1h-1zM11 23h2v1h-2zM14 23h1v1h-1zM9 24h6v1h-6zM10 25h1v1h-1zM13 25h1v1h-1zM11 26h2v1h-2z"/><path fill="#1b1626" d="M8 15h1v1h-1zM15 15h1v1h-1zM8 16h1v1h-1zM15 16h1v1h-1z"/><path fill="#f08c7c" d="M11 16h2v1h-2zM11 17h2v1h-2z"/><path fill="#ffb0a0" d="M10 17h1v1h-1z"/><path fill="#c8645a" d="M13 17h1v1h-1zM10 18h4v1h-4z"/><path fill="#ffb05a" d="M6 18h1v1h-1zM6 19h1v1h-1zM6 20h1v1h-1zM7 21h1v1h-1zM7 22h1v1h-1zM8 23h1v1h-1zM8 24h1v1h-1zM9 25h1v1h-1zM10 26h1v1h-1zM11 27h1v1h-1z"/><path fill="#a4501c" d="M17 18h1v1h-1zM17 19h1v1h-1zM10 20h1v1h-1zM13 20h1v1h-1zM17 20h1v1h-1zM10 21h1v1h-1zM13 21h1v1h-1zM16 21h1v1h-1zM9 22h1v1h-1zM14 22h1v1h-1zM16 22h1v1h-1zM10 23h1v1h-1zM13 23h1v1h-1zM15 23h1v1h-1zM15 24h1v1h-1zM11 25h2v1h-2zM14 25h1v1h-1zM13 26h1v1h-1zM12 27h1v1h-1z"/><path fill="#8fd06a" d="M4 20h1v1h-1zM4 21h1v1h-1zM4 22h1v1h-1zM4 23h1v1h-1zM4 24h1v1h-1zM4 26h1v1h-1z"/><path fill="#3d7a2a" d="M19 20h1v1h-1zM19 21h1v1h-1zM19 22h1v1h-1zM19 23h1v1h-1zM19 24h1v1h-1zM19 26h1v1h-1zM4 27h6v1h-6zM14 27h6v1h-6z"/><path fill="#5fa83f" d="M5 21h1v1h-1zM18 21h1v1h-1zM5 22h1v1h-1zM18 22h1v1h-1zM5 23h2v1h-2zM17 23h2v1h-2zM5 24h2v1h-2zM17 24h2v1h-2zM5 26h4v1h-4zM15 26h4v1h-4z"/><path fill="#6b3f22" d="M4 25h4v1h-4zM16 25h4v1h-4z"/><path fill="#6a4126" d="M6 28h5v1h-5zM13 28h5v1h-5zM6 29h5v1h-5zM13 29h5v1h-5z"/><path fill="#46271a" d="M6 30h5v1h-5zM13 30h5v1h-5z"/></svg>`

// grid5 and grid38 are the grids that the spec shows for the seeds gnome-5 and gnome-38.
const grid5 = `.........oooo...........
........ohjHjo..........
.......oHjoHjo..........
.......ohoohjo..........
........ooHHHjo.........
.........ohHHjo.........
........oHHHHHjo........
........ohHHHHjo........
.......oHHHHHHHjo.......
.......ohHHHHHHjo.......
......oHjjjjjjjjjo......
....ohHHHHHHHHHHHHjo....
....ojjjjjjjjjjjjjjo....
......ouuuuuuuuuuo......
......osWWWssWWWso......
.....osgggssssgggso.....
....ousgeggnnggegsuo....
......ogggmnnvgggo......
.....owWWWvvvvWWWxo.....
....oowWWWWWWWWWWxoo....
...ocCowWWWWWWWWxoCdo...
...ocCowWWxWWxWWxoCdo...
...ocCCowWWWWWWxoCCdo...
..oscCCowWxWWxWxoCCdso..
..oucCCCowWWWWxoCCCduo..
...okkkkowWxxWxokkkko...
...ocCCCCowWWxoCCCCdo...
...odddddowxxxodddddo...
.....opppppoopppppo.....
.....opppppoopppppo.....
.....oqqqqqooqqqqqo.....
.....oooooooooooooo.....`

const grid38 = `...........oo...........
..........ohjo..........
..........oHHo..........
.........ohHHjo.........
.........oHHHHo.........
........ohHHHHjo........
........oHHHHHHo........
.......ohHHHHHHjo.......
.......oHHHHHHHHo.......
......ohHHHHHHHHjo......
......oHHHHHHHHHHo......
....ohHHHHHHHHHHHHjo....
....ojjjjjjjjjjjjjjo....
......ouuuuuuuuuuo......
......osWWWssWWWso......
.....ossessssssesso.....
....oussessnnssessuo....
......osssmnnvssso......
......osssvvvvssso......
....ocosssuuuusssodo....
...ocCCossssssssoCCdo...
...ocCCCooooooooCCCdo...
...ocCCCCCCCCCCCCCCdo...
..oscCCCCCCCCCCCCCCdso..
..oucCCCCCCCCCCCCCCduo..
...okkkkkkkyykkkkkkko...
...ocCCCCCCCCCCCCCCdo...
...oddddddddddddddddo...
.....opppppoopppppo.....
.....opppppoopppppo.....
.....oqqqqqooqqqqqo.....
.....oooooooooooooo.....`

func sha(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// checkCase compares a golden case with the output of Pack, Unpack, BuildGrid and RenderSVG.
func checkCase(t *testing.T, c goldenCase, name string) {
	t.Helper()

	assert(t, Pack(c.traits) == c.packed, name+": packed value")
	assert(t, Unpack(c.packed) == c.traits, name+": unpacked traits")

	grid := BuildGrid(c.traits)
	assert(t, len(grid) == 32, name+": grid rows")
	assertEqual(t, sha(strings.Join(grid, "\n")), c.gridSHA, name+": grid")

	svg := RenderSVG(c.traits, Options{})
	assert(t, len(svg) == c.svgLen, name+": svg length")
	assertEqual(t, sha(svg), c.svgSHA, name+": svg")
}

// The seeds of the spec (section 10), including the digest bytes that the traits come from.
func TestSpecVectors(t *testing.T) {
	for i, sv := range specSeeds {
		g := goldenSeeds[i]
		assertEqual(t, g.seed, sv.seed, "golden seed")

		d := sha256.Sum256([]byte(sv.seed))
		assertEqual(t, hex.EncodeToString(d[:11]), sv.digest, sv.seed+" digest")
	}
}

func TestSeeds(t *testing.T) {
	for _, c := range goldenSeeds {
		tr := NewTraits(c.seed)
		assert(t, tr == c.traits, "traits of seed "+c.seed)
		assert(t, tr.Validate() == nil, "valid traits of seed "+c.seed)
		checkCase(t, c, "seed "+c.seed)
	}
}

func TestTraits(t *testing.T) {
	for i, c := range goldenTraits {
		checkCase(t, c, "traits case "+strconv.Itoa(i))
	}
}

func TestSpecExamples(t *testing.T) {
	assertEqual(t, RenderSeed("alice", Options{}), aliceSVG, "alice svg")
	assertEqual(t, strings.Join(BuildGrid(NewTraits("gnome-5")), "\n"), grid5, "gnome-5 grid")
	assertEqual(t, strings.Join(BuildGrid(NewTraits("gnome-38")), "\n"), grid38, "gnome-38 grid")
}

