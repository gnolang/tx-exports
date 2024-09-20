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
	DomainName string
	Bidder     std.Address
	HashString string
	Price      int
	StartTime  time.Time
	EndTime    time.Time
	IsOpen     bool
}

var (
	BidRec    *avl.Tree // bidRecord <- []bidRec
	winnerRec *avl.Tree
)

// pending logic
func startBiddingSession(domainName string) (result string) {
	ufmt.Println("start bidding session")
	return "ok"
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

// commit the domain name and computed hash string
func CommitHash(domainName, hashString string) bidStatus {
	bStt := bidStatus{}
	caller := std.GetOrigCaller()
	ufmt.Println("caller: ", caller.String())
	now := time.Now()
	endTime := now.Add(defaultCommitHashTime)

	// update the bid record
	data, existed := BidRec.Get(domainName)

	// if not existed -> create new record
	if !existed {
		var bidRec bidRecord
		bidRec = bidRecord{
			DomainName: domainName,
			Bidder:     caller,
			HashString: hashString,
			StartTime:  now,
			EndTime:    endTime,
			IsOpen:     true,
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
	// TODO: Check if commit more than 1 time
	bidRecList := data.([]bidRecord)
	ufmt.Println("now: ", time.Now().Format(time.RFC3339))
	ufmt.Println("bidRec0: ", bidRecList[0].EndTime.Format(time.RFC3339))
	startTime := bidRecList[0].StartTime
	if now.After(bidRecList[0].EndTime) {
		panic("can not commit hash anymore")
	}
	for _, bR := range bidRecList {
		if bR.Bidder == caller {
			panic("commit 1 time per user")
		}
	}

	bidRec := bidRecord{
		DomainName: domainName,
		HashString: hashString,
		Bidder:     caller,
		StartTime:  startTime,
		EndTime:    endTime,
		IsOpen:     true,
	}
	bidRecList = append(bidRecList, bidRec)
	// Save record
	BidRec.Set(domainName, bidRecList)
	// charge fee
	chargeFee(fee.BidJoinFee, caller)
	bStt.CurrentStatus = AppendBiddingSession
	bStt.ActionCode = CommitPricePhase
	return bStt
}

// commit price and secret to reveal auction session
func CommitPrice(price int, secret string, domainName string) bidStatus {
	// compute the hash string, compare to saved hash string in record
	var bStt bidStatus
	// joinedString = (secret || price)
	now := time.Now()
	tempJoinString := secret + strconv.Itoa(price)
	ufmt.Println("joined string: ", tempJoinString)
	computedHashString := Get256String(tempJoinString)
	ufmt.Println("computed hash: ", computedHashString)
	caller := std.GetOrigCaller()
	data, existed := BidRec.Get(domainName)
	if !existed {
		panic("CommitPrice: domain name is invalid")
	}
	bidRecList := data.([]bidRecord)
	winnerRec.Set(domainName, bidRecList[0])
	for _, bidRec := range bidRecList {
		// case commit after end
		if now.After(bidRec.EndTime) {
			bStt.CurrentStatus = BiddingSessionClosed
			bStt.ActionCode = 0
			return bStt
		}
		if bidRec.Bidder == caller && bidRec.HashString != computedHashString {
			bStt.CurrentStatus = AppendBiddingSession
			bStt.ActionCode = ActionFailed
			return bStt
		}
		// found it, update the winner price
		if bidRec.Bidder == caller && bidRec.HashString == computedHashString {
			data, _ := winnerRec.Get(domainName)
			currentWinnerRec := data.(bidRecord)
			if price > currentWinnerRec.Price && now.Before(currentWinnerRec.EndTime) {
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
	bStt.CurrentStatus = StatusFailed
	bStt.ActionCode = ActionFailed
	return bStt
}

func GetCurrentWinner(domainName string) bidRecord {
	data, existed := winnerRec.Get(domainName)
	if !existed {
		panic("no winner yet")
	}
	return data.(bidRecord)
}

// func savePrice(price int, domainName string, rec bidRecord) bool {
// 	rec.Price = price
// 	bidRecFinal := []bidRecord{rec}
// 	ok := BidRec.Set(domainName, bidRecFinal)
// 	if !ok {
// 		panic("SavePrice: can not update record")
// 	}
// 	return true
// }

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
	timeNowDebug := now.Format(time.RFC3339)
	endTimeDebug := firstBidRec.EndTime.Format(time.RFC3339)
	ufmt.Println("now: ", timeNowDebug, "endTime: ", endTimeDebug)
	if now.Before(firstBidRec.EndTime) {
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

// open a bidding session
func openBiddingSession(domainName string, dur time.Duration) string {
	now := time.Now()
	bidRec := bidRecord{
		DomainName: domainName,
		StartTime:  now,
	}
	bidRecList := []bidRecord{bidRec}
	ok := BidRec.Set(domainName, bidRecList)
	if !ok {
		panic("can not open bidding session")
	}
	return "created bidding session"
}

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

// get all the record
func GetRecord(dName string) (priceList []int, hashList []string) {
	data, existed := BidRec.Get(dName)
	if !existed {
		panic("should not")
	}
	rList := data.([]bidRecord)
	for _, r := range rList {
		priceList = append(priceList, r.Price)
		hashList = append(hashList, r.HashString)
	}
	return priceList, hashList
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
	feeProcess(requestInfo)
	return true
}
