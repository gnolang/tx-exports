// PKGPATH: gno.land/r/g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj/tavernboard/filetests/z_tip_filetest

package z_tip_filetest

// SEND: 1000000ugnot

// Tip-flow tests for Tavern Board. In a filetest, testing.SetRealm mutates
// the CURRENT FRAME's captured cur, so it must be called directly in main
// (not via a helper — a helper's SetRealm only changes the helper's frame
// and is lost on return). After SetRealm, cross(cur) calls the realm as a
// real user realm, which the OriginSend guard in TipPost/TipReply requires.
// This is the same mechanism the boards filetests use (SetRealm in main,
// then cross(cur)).

import (
	"chain"
	"chain/banker"
	"strconv"
	"testing"

	"gno.land/r/g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj/tavernboard"
)

// Throwaway test-only addresses (local gnokey keys tb_author2..5, tb_tipper1).
const (
	author2 = address("g14xs54wpddt0c3e5dv075528r9nw75tlp6a0hp2")
	author3 = address("g1qfz4kvxqvz574nfn9nwvx6knx3h7359yjs98vz")
	author4 = address("g1thvs44g9zjxumsgxhjj2edk6we2kesl7hnsg9s")
	author5 = address("g10zq4tjszsa82f36nywgnh7u95uqazrv0544zzy")
	tipper1  = address("g1wxuxfpntesp0pzfmlp4ygcc2ekhv3u0e3uc5sn")
)

// check panics with msg when cond is false.
func check(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}

// checkErr panics with msg + the error when err is non-nil.
// (Never call err.Error() on a possibly-nil error: it panics.)
func checkErr(err error, msg string) {
	if err != nil {
		panic(msg + ": " + err.Error())
	}
}

// tavernAddr is this realm's package address: the RealmSend banker spends
// from the realm's own balance, so the test funds it directly (IssueCoins),
// simulating the send envelope landing at the realm in a real MsgCall.
var tavernAddr = chain.PackageAddress("gno.land/r/g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj/tavernboard")

// fund credits `amount` ugnot to the realm and sets the send envelope for
// a tip call (machine-global, safe in a helper). The caller realm itself
// is set inline in main via SetRealm.
func fund(amount int64) {
	testing.IssueCoins(tavernAddr, chain.Coins{{"ugnot", amount}})
	testing.SetOriginSend(chain.Coins{{"ugnot", amount}})
}

func main(cur realm) {
	// --- TipPost: author receives the coins, totals update. ---
	testing.SetRealm(testing.NewUserRealm(author2))
	postID, err := tavernboard.CreatePost(cross(cur), "Tip me", "Worth a tip")
	checkErr(err, "CreatePost failed")
	post, ok := tavernboard.GetPost(postID)
	check(ok, "GetPost failed after create")
	check(post.Author == author2, "post author is not author2: "+post.Author.String())
	fund(1500)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), postID, 1000)
	checkErr(err, "TipPost failed")
	post, _ = tavernboard.GetPost(postID)
	check(post.TipTotal == 1000, "post TipTotal "+strconv.Itoa(int(post.TipTotal))+" != 1000")
	check(tavernboard.GetAuthorTips(author2) == 1000, "author tips != 1000")
	bal := banker.NewReadonlyBanker().GetCoin(author2, "ugnot")
	check(bal == 1000, "author balance "+strconv.Itoa(int(bal))+" != 1000")
	// Leftover (1500 sent - 1000 tipped) is refunded to the tipper.
	tipBal := banker.NewReadonlyBanker().GetCoin(tipper1, "ugnot")
	check(tipBal == 500, "tipper refund balance "+strconv.Itoa(int(tipBal))+" != 500")

	// --- TipPost validation ---
	fund(1000)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), 999999, 1000)
	check(err != nil, "tip to missing post should fail")
	err = tavernboard.TipPost(cross(cur), postID, 0)
	check(err != nil, "zero tip should fail")
	err = tavernboard.TipPost(cross(cur), postID, -5)
	check(err != nil, "negative tip should fail")
	testing.SetOriginSend(chain.Coins{{"ugnot", 100}})
	err = tavernboard.TipPost(cross(cur), postID, 1000)
	check(err != nil, "tip larger than sent amount should fail")

	// --- TipReply: reply author receives the coins. ---
	testing.SetRealm(testing.NewUserRealm(author3))
	postID2, err := tavernboard.CreatePost(cross(cur), "Reply tip target", "body")
	checkErr(err, "CreatePost failed")
	testing.SetRealm(testing.NewUserRealm(author2))
	replyID, err := tavernboard.CreateReply(cross(cur), postID2, "Helpful reply")
	checkErr(err, "CreateReply failed")
	fund(500)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipReply(cross(cur), postID2, replyID, 500)
	checkErr(err, "TipReply failed")
	replies := tavernboard.GetReplies(postID2)
	check(len(replies) == 1 && replies[0].TipTotal == 500, "reply TipTotal != 500")
	check(tavernboard.GetAuthorTips(author2) == 1500, "reply author tips != 1500 (1000 post + 500 reply)")
	bal = banker.NewReadonlyBanker().GetCoin(author2, "ugnot")
	check(bal == 1500, "reply author balance "+strconv.Itoa(int(bal))+" != 1500")

	// --- TipReply validation ---
	fund(100)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipReply(cross(cur), 999999, replyID, 100)
	check(err != nil, "tip reply on missing post should fail")
	err = tavernboard.TipReply(cross(cur), postID2, 999999, 100)
	check(err != nil, "tip to missing reply should fail")
	err = tavernboard.TipReply(cross(cur), postID2, replyID, 0)
	check(err != nil, "zero reply tip should fail")

	// --- Leaderboard: posts ranked by tips, relative order. ---
	testing.SetRealm(testing.NewUserRealm(author4))
	pLow, err := tavernboard.CreatePost(cross(cur), "Low tips", "body")
	checkErr(err, "CreatePost failed")
	pHigh, err := tavernboard.CreatePost(cross(cur), "High tips", "body")
	checkErr(err, "CreatePost failed")
	pMid, err := tavernboard.CreatePost(cross(cur), "Mid tips", "body")
	checkErr(err, "CreatePost failed")
	fund(100)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), pLow, 100)
	checkErr(err, "TipPost low failed")
	fund(500)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), pHigh, 500)
	checkErr(err, "TipPost high failed")
	fund(300)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), pMid, 300)
	checkErr(err, "TipPost mid failed")
	ordered := tavernboard.GetPosts()
	idx := func(id int) int {
		for i, p := range ordered {
			if p.ID == id {
				return i
			}
		}
		return -1
	}
	iHigh, iMid, iLow := idx(pHigh), idx(pMid), idx(pLow)
	check(iHigh >= 0 && iMid >= 0 && iLow >= 0, "posts missing from leaderboard")
	check(iHigh < iMid && iMid < iLow, "leaderboard order wrong: high="+strconv.Itoa(iHigh)+" mid="+strconv.Itoa(iMid)+" low="+strconv.Itoa(iLow))

	// --- GetAuthorTips: fresh author, 0 before, 250 after. ---
	testing.SetRealm(testing.NewUserRealm(author5))
	postID3, err := tavernboard.CreatePost(cross(cur), "Author tips", "body")
	checkErr(err, "CreatePost failed")
	check(tavernboard.GetAuthorTips(author5) == 0, "author tips before tip != 0")
	fund(250)
	testing.SetRealm(testing.NewUserRealm(tipper1))
	err = tavernboard.TipPost(cross(cur), postID3, 250)
	checkErr(err, "TipPost failed")
	check(tavernboard.GetAuthorTips(author5) == 250, "author tips after tip != 250")

	println("TIP TESTS OK")
}

// Output:
// TIP TESTS OK
