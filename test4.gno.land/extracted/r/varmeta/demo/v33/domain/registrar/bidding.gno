package registrar

import (
	"std"
	"strconv"
	"time"

	"gno.land/p/demo/ufmt"
	// "gno.land/p/demo/mux"
	"gno.land/p/demo/avl"
)

type bidRecord struct {
	DomainName    string
	Bidder        std.Address
	HashString    string
	Price         int
	StartTime     time.Time
	EndCommitTime time.Time
	EndPriceTime  time.Time
	CurrentPhase  actionCode
	IsOpen        bool
}

var (
	BidRec    *avl.Tree // bidRecord <- []bidRec
	winnerRec *avl.Tree
	joinedBid avl.Tree
)

// joinedBid: address <- []domainName
func recordJoinedBid(domainName string) {
	caller := std.GetOrigCaller()
	dList := []string{}
	data, existed := joinedBid.Get(domainName)
	if !existed {
		dList = []string{domainName}
		joinedBid.Set(caller.String(), dList)
		return
	}
	dList = data.([]string)
	dList = append(dList, domainName)
	joinedBid.Set(caller.String(), dList)
	return
}

// get the joined bids of an account
func GetJoinedBid() []string {
	caller := std.GetOrigCaller().String()
	data, existed := joinedBid.Get(caller)
	if !existed {
		return []string{}
	}
	list := data.([]string)
	return list
}

// get the next state of bidding session
func GetCurrentStatus(domainName string) string {
	// if there is record in joinedBid -> user joined
	// check for tine.Now() and startTime
	now := time.Now()
	caller := std.GetOrigCaller()
	// find the record
	data, existed := BidRec.Get(domainName)
	if !existed {
		if _, existedInRegister := joinedBid.Get(caller.String()); existedInRegister {
			return "hash"
		}
		ufmt.Println("run here")
		return "dName is invalid"
	}
	recList := data.([]bidRecord)
	rec := recList[0]

	if now.Before(rec.EndCommitTime) {
		return "waiting price"
	}
	if now.Before(rec.EndPriceTime) && now.After(rec.EndCommitTime) {
		return "price"
	}
	if now.After(rec.EndPriceTime) {
		return "closed"
	}
	return "undefined"
}

// Render() renders welcome message :D
func Render(path string) string {
	return "welcome to varmeta domain name service"
}

/*
	logic should be:
	1. User click register for a dns.
	-> 1.1: dns does not exists -> open bidding session
	-> 1.2: dns existed -> check if open bidding session is openning or not -> if open -> new bidRecord
	2. Bidding session:
	-> 2.1: CommitHash phase: commit hashed string (price || secret string) + send joining fee -> creat bidRecord to add to bidRec
	-> 2.2: CommitPrice phase: commit price + secret key: -> if matches -> write price into bidRec ( send the amunt of coin corresponding)
	-> 2.3(?): after CommitPrice phase done, get the winner and register domain for winner by a `Claim` button
	---> admin end bidding auction
	-> 2.3.1: cooldown phase -> waiting for winner -> 2nd winner
	-> 2.4: re-transfer coin from admin to user who not win the bid
		the flow is: user want to register new domain name -> start new bidding session -> got the bidding session id
		if other want to register to the same domain name -> bidding into this session, if not return to new state
		when the session ends, need to have 2nd phase called commit -> commit their price and secret to compute the hash
		-> compare the hash as in record -> accept the hash -> accept the price
		*** temp approach: everytime user commit, user open a bid session if not existed, if existed -> check if this session is ended.
*/
// in commit hash phase, we calcute the time stamp of phase 1, phase 2. by this, we not need to recalculate
// the time whenever there is action to commit.

// commit the domain name and computed hash string
func CommitHash(domainName, hashString string) bidStatus {
	bStt := bidStatus{}
	caller := std.GetOrigCaller()
	ufmt.Println("caller: ", caller.String())
	now := time.Now()

	// update the bid record
	data, existed := BidRec.Get(domainName)

	// if not existed -> create new record
	if !existed {
		var bidRec bidRecord
		endCommitTime := now.Add(defaultCommitHashTime)
		endPriceTime := endCommitTime.Add(defaultCommitPriceTime)
		ufmt.Println("endCommitTime: ", endCommitTime.Format(time.RFC3339))
		ufmt.Println("endPriceTime: ", endPriceTime.Format(time.RFC3339))
		bidRec = bidRecord{
			DomainName:    domainName,
			Bidder:        caller,
			HashString:    hashString,
			StartTime:     now,
			EndCommitTime: endCommitTime,
			EndPriceTime:  endPriceTime,
			IsOpen:        true,
		}
		bidRecList := []bidRecord{bidRec}
		BidRec.Set(domainName, bidRecList)

		// charge fee
		chargeFee(fee.BidJoinFee, caller)
		bStt.CurrentStatus = NewBiddingSession
		bStt.ActionCode = CommitPricePhase
		return bStt
	}
	// if existed
	// TODO: Check if commit more than 1 time -> done
	bidRecList := data.([]bidRecord)
	startTime := bidRecList[0].StartTime
	if now.After(bidRecList[0].EndCommitTime) {
		panic("can not commit hash anymore")
	}
	for _, bR := range bidRecList {
		if bR.Bidder == caller {
			panic("you already commited hash")
		}
	}

	oldEndCommitTime := bidRecList[0].EndCommitTime
	oldEndPriceTime := bidRecList[0].EndPriceTime
	bidRec := bidRecord{
		DomainName:    domainName,
		HashString:    hashString,
		Bidder:        caller,
		StartTime:     startTime,
		EndCommitTime: oldEndCommitTime,
		EndPriceTime:  oldEndPriceTime,
		IsOpen:        true,
	}
	bidRecList = append(bidRecList, bidRec)
	// Save record
	BidRec.Set(domainName, bidRecList)
	// charge commit hash fee
	chargeFee(fee.BidJoinFee, caller)
	bStt.CurrentStatus = AppendBiddingSession
	bStt.ActionCode = CommitPricePhase
	return bStt
}

// for now we dont use panic because this will cause the permanent time.Now() stuck. IDK why // XXX fix me
// commit price and secret to reveal auction session
func CommitPrice(price int, secret string, domainName string) bidStatus {
	var bStt bidStatus
	// compute the hash string, compare to saved hash string in record
	now := time.Now()
	joinedString := secret + strconv.Itoa(price)
	computedHashString := Get256String(joinedString)
	ufmt.Println("computed hash: ", computedHashString)
	caller := std.GetOrigCaller()
	data, existed := BidRec.Get(domainName)
	if !existed {
		panic(" domain name is invalid")
	}
	bidRecList := data.([]bidRecord)
	winnerRec.Set(domainName, bidRecList[0])

	ufmt.Println("time now: ", now.Format(time.RFC3339))
	ufmt.Println("end commit phase time: ", bidRecList[0].EndCommitTime.Format(time.RFC3339))
	// case commit after end - consider panic or not
	if now.After(bidRecList[0].EndPriceTime) {
		ufmt.Println("commit price phase is ended")
		bStt.ActionCode = 0
		bStt.CurrentStatus = 0
		return bStt
	}
	// case commit when price phase not started
	if time.Now().Before(bidRecList[0].EndCommitTime) {
		ufmt.Println("commit price phase is not started yet")
		bStt.ActionCode = 0
		bStt.CurrentStatus = 0
		return bStt
	}

	// search for the corresponding hash
	for _, bidRec := range bidRecList {
		// panic because wrong price or wrong secret string
		if bidRec.Bidder == caller && bidRec.HashString != computedHashString {
			panic("invalid hash string")
		}
		// found it, update the winner price
		if bidRec.Bidder == caller && bidRec.HashString == computedHashString {
			data, _ := winnerRec.Get(domainName)
			currentWinnerRec := data.(bidRecord)
			if price > currentWinnerRec.Price && now.Before(currentWinnerRec.EndPriceTime) {
				ufmt.Println("found new winner, setting up")
				currentWinnerRec.Price = price
				currentWinnerRec.Bidder = bidRec.Bidder
				currentWinnerRec.HashString = bidRec.HashString
				winnerRec.Set(domainName, currentWinnerRec)
				bStt.ActionCode = ClaimPhase
				return bStt
			}
		}
	}
	// if not match above case, then panic
	panic("commit failed")
}

func GetCurrentWinner(domainName string) bidRecord {
	data, existed := winnerRec.Get(domainName)
	if !existed {
		panic("no winner yet")
	}
	return data.(bidRecord)
}

// find the highest bid in session - incase everyone commited price
func findTheWinner(domainName string) bidRecord {
	var winnerBid bidRecord
	data, existed := BidRec.Get(domainName)
	if !existed {
		panic("invalid domain name")
	}
	bidRecList := data.([]bidRecord)
	winnerBid = bidRecList[0]
	for _, bidRec := range bidRecList {
		if bidRec.Price > winnerBid.Price {
			winnerBid = bidRec
		}
	}
	return winnerBid
}

// register the domain for winner
func registerForWinner(domainName string, winnerRec bidRecord) bool {
	winnerAddr := winnerRec.Bidder
	requestInfo := RequestInfo{
		WantedDomain: domainName,
		Caller:       winnerAddr,
		Mode:         "native",
	}
	result := executeRegister(requestInfo)
	if !result.Success {
		panic(result.ResultDetails.Error())
	}
	// register done. Now charge the fee
	feeProcess(requestInfo)
	return false
}

// everyone can call EndBid()
// this EndBid checks endTime -> end the auction
func EndBid(domainName string) error {
	now := time.Now()
	data, existed := BidRec.Get(domainName)
	if !existed {
		return ufmt.Errorf("endbid: invalid domain name")
	}
	bidRecList := data.([]bidRecord)
	firstBidRec := bidRecList[0]
	if now.Before(firstBidRec.EndPriceTime) {
		return ufmt.Errorf("endbid: this session can not end before the end time")
	}
	// change all state
	for _, bidRec := range bidRecList {
		bidRec.IsOpen = false
	}
	ok := BidRec.Set(domainName, bidRecList)
	if !ok {
		return ufmt.Errorf("endbid: can not change bid record state")
	}
	// need more conditions for findTheWinner()
	findTheWinner(domainName)
	return nil
}

// register new domain with bidding process inside - if message is commit hash -> dapp need to call commit hash
func RegisterDomain(domainName string) bidStatus {
	reqInfo := RequestInfo{
		WantedDomain: domainName,
		Caller:       std.PrevRealm().Addr(),
		Mode:         "native",
	}

	// bidStatus
	result := checkRegisterState(reqInfo)
	recordJoinedBid(domainName)
	// if checkState get the message of which phase this domain name belongs to, then return the status
	return result
}

func checkRegisterState(req RequestInfo) bidStatus {
	var bStt bidStatus
	// check if domain name is regex valid
	if !isValidDomain(req.WantedDomain) {
		panic("invalid domain name")
	}
	// check if dName is registered
	if AlreadyRegistered(req.WantedDomain) {
		panic("domain name already registered")
	}
	// changelogs v2: we are using sealed bidding now
	// check if a bidding session is openning -> append new commit hash into record list
	// both existed or not we open new bidding session
	// for now we return a signal for dapps / service to know what to do next
	isExisted, isOpen := checkBiddingState(req.WantedDomain)
	if isExisted && isOpen {
		// return commit hash signal for dapps
		bStt.CurrentStatus = AppendBiddingSession
		bStt.ActionCode = CommitHashPhase
		return bStt
	}

	// create new session
	if !isExisted {
		bStt.CurrentStatus = NewBiddingSession
		bStt.ActionCode = CommitHashPhase
		return bStt
	}

	// not found in register repository but also not found in Bidding Record -> panic("error somewhere :D")
	panic(ufmt.Errorf("should not happend"))
	return bStt
}

// // open a bidding session
// func openBiddingSession(domainName string, dur time.Duration) string {
// 	now := time.Now()
// 	bidRec := bidRecord{
// 		DomainName: domainName,
// 		StartTime:  now,
// 	}
// 	bidRecList := []bidRecord{bidRec}
// 	ok := BidRec.Set(domainName, bidRecList)
// 	if !ok {
// 		panic("can not open bidding session")
// 	}
// 	return "created bidding session"
// }

func checkBiddingState(dName string) (isExisted bool, isOpen bool) {
	data, existed := BidRec.Get(dName)
	if !existed {
		isExisted = false
		isOpen = false
		return
	}
	isExisted = true
	recList := data.([]bidRecord)
	if recList[0].IsOpen {
		isOpen = true
	} else {
		isOpen = false
	}
	return isExisted, isOpen
}

// get all the price list that joined the bid for displaying in dapp
func GetRecords(dName string) []bidRecord {
	data, existed := BidRec.Get(dName)
	if !existed {
		panic("should not")
	}
	return data.([]bidRecord)
}

// chargeFee will charge amount - send from this contract to admin
func chargeFee(amount int64, from std.Address) {
	bankerContract := std.CurrentRealm().Addr()
	ugnotCoin := std.NewCoin("ugnot", amount)
	coinsToTransfer := std.NewCoins(ugnotCoin)
	coins := checkCoin(from)
	ufmt.Println("check balances: ", coins)
	ufmt.Println("send from contract ", bankerContract.String(), " to admin ", admin.String(), " amount: ", ugnotCoin)
	bankerUser.SendCoins(bankerContract, admin, coinsToTransfer)
}

// pay fee and claim the domain name if you are winner
func Claim(domainName string) bool {
	data, existed := winnerRec.Get(domainName)
	if !existed {
		panic("claim: invalid domain name")
	}
	caller := std.GetOrigCaller()
	rec := data.(bidRecord)
	if caller != rec.Bidder {
		panic("only winner can claim")
	}
	requestInfo := RequestInfo{
		WantedDomain: domainName,
		Caller:       rec.Bidder,
		Mode:         "native",
	}
	result := executeRegister(requestInfo)
	if !result.Success {
		panic(result.ResultDetails.Error())
	}
	// register done. Now charge the fee
	chargeFee(100, caller)
	feeProcess(requestInfo)
	return true
}
