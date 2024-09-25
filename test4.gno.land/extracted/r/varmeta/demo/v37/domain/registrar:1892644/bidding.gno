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
	StartTime     int64
	EndCommitTime int64
	EndPriceTime  int64
	IsOpen        bool
	// CurrentPhase  actionCode
}

var (
	bidStorage *avl.Tree // bidRecord <- []bidRec
	winnerRec  *avl.Tree // std.Address <- bidRec
	joinedBid  avl.Tree  // address <- []string DomainName
)

// joinedBid: address <- []domainName
func recordJoinedBid(domainName string) {
	caller := std.GetOrigCaller()
	dList := []string{}
	data, existed := joinedBid.Get(caller.String())
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
// want to return both name and status
func GetJoinedBid(caller string) []singleStatus {
	data, existed := joinedBid.Get(caller)
	if !existed {
		return []singleStatus{}
	}
	list := data.([]string)
	listStatus := []singleStatus{}
	for _, dName := range list {
		stt := GetCurrentStatus(dName, caller)
		singleStt := singleStatus{
			DomainName: dName,
			Status:     stt,
		}
		listStatus = append(listStatus, singleStt)
	}
	return listStatus
}

// get the next state of bidding session
// XXX note commit price status + if time is expired and not commited yet
// status clear
func GetCurrentStatus(domainName string, caller string) string {
	// if there is record in joinedBid -> user joined
	// check for tine.Now() and startTime
	now := time.Now().UnixMilli()
	owner := GetOwner(domainName)
	if owner != "" {
		return "owned by " + owner.String()
	}
	// find the record
	data, existed := bidStorage.Get(domainName)
	if !existed {
		// no record in bidRec yet -> not commited -> check if user started auction or not - if yes: new auction
		if _, existedInRegister := joinedBid.Get(caller); existedInRegister {
			return "new auction"
		}
		return "domain name is free"
	}

	// commited yet
	recList := data.([]bidRecord)
	rec := recList[0]
	endCommitTimeUnix := rec.EndCommitTime
	endPriceTimeUnix := rec.EndPriceTime
	if now < endCommitTimeUnix {
		if rec.HashString != "" {
			return "commited hash"
		} else {
			return "hash"
		}
	}

	ufmt.Println("now: ", time.UnixMilli(now))
	ufmt.Println("endPriceTime: ", time.UnixMilli(endPriceTimeUnix))
	if now < endPriceTimeUnix && now > endCommitTimeUnix {
		return "price"
	}
	if now > rec.EndPriceTime {
		return "closed"
	}
	return "undefined"
}

// Render() renders welcome message :D
func Render(path string) string {
	return "welcome to varmeta domain name service"
}

// commit the domain name and computed hash string
func CommitHash(domainName, hashString string) string {
	caller := std.GetOrigCaller()

	// use now as int64 representation of time.Now()
	now := time.Now().UnixMilli()

	// update the bid record
	data, existed := bidStorage.Get(domainName)

	// if not existed -> create new record
	if !existed {
		// for further getStatus
		recordJoinedBid(domainName)

		var bidRec bidRecord
		endCommitTime := now + defaultCommitHashTime.Milliseconds()
		endPriceTime := endCommitTime + defaultCommitPriceTime.Milliseconds()
		ufmt.Println("[HASH]: endCommitTime: ", time.UnixMilli(endCommitTime))
		ufmt.Println("[HASH]: endPriceTime: ", time.UnixMilli(endPriceTime))
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
		bidStorage.Set(domainName, bidRecList)

		// charge fee
		chargeFee(fee.BidJoinFee, caller)
		return "new session"
	}
	// if existed
	bidRecList := data.([]bidRecord)
	startTime := bidRecList[0].StartTime
	oldEndCommitTimeUnix := bidRecList[0].EndCommitTime
	oldEndPriceTimeUnix := bidRecList[0].EndPriceTime
	if now > oldEndCommitTimeUnix {
		// now := time.Now().UnixMilli()
		// ufmt.Println("[HASH]: now: ", time.UnixMilli(now))
		panic("[HASH]: can not commit hash anymore")
	}
	for _, bR := range bidRecList {
		if bR.Bidder == caller {
			panic("[HASH]: you already commited hash")
		}
	}

	bidRec := bidRecord{
		DomainName:    domainName,
		HashString:    hashString,
		Bidder:        caller,
		StartTime:     startTime,
		EndCommitTime: oldEndCommitTimeUnix,
		EndPriceTime:  oldEndPriceTimeUnix,
		IsOpen:        true,
	}
	bidRecList = append(bidRecList, bidRec)
	// Save record
	bidStorage.Set(domainName, bidRecList)
	// charge commit hash fee
	chargeFee(fee.BidJoinFee, caller)
	return "existed"
}

// for now we dont use panic because this will cause the permanent time.Now() stuck. IDK why // XXX fix me
// commit price and secret to reveal auction session
func CommitPrice(price int, secret string, domainName string) string {
	// compute the hash string, compare to saved hash string in record
	// use int64 representation of time.Now()
	now := time.Now().UnixMilli()
	joinedString := secret + strconv.Itoa(price)
	computedHashString := Get256String(joinedString)
	ufmt.Println("[PRICE]: computed hash : ", computedHashString, "domain ", domainName)
	caller := std.GetOrigCaller()
	data, existed := bidStorage.Get(domainName)
	if !existed {
		panic("[PRICE]: domain name is invalid")
	}
	bidRecList := data.([]bidRecord)
	winnerRec.Set(domainName, bidRecList[0])

	ufmt.Println("[PRICE]: time now: ", time.UnixMilli(now))
	ufmt.Println("[PRICE]: endPriceTime: ", time.UnixMilli(bidRecList[0].EndPriceTime))
	// case commit after end - consider panic or not
	if now > bidRecList[0].EndPriceTime {
		ufmt.Println("[PRICE]: commit price phase is ended")
		return "ended"
	}
	// case commit when price phase not started
	if now <= bidRecList[0].EndCommitTime {
		ufmt.Println("[PRICE]: commit price phase is not started yet")
		return "not started yet"
	}

	// search for the corresponding hash
	for _, bidRec := range bidRecList {
		// panic because wrong price or wrong secret string
		if bidRec.Bidder == caller && bidRec.HashString != computedHashString {
			panic("[PRICE]: invalid hash string")
		}
		// found it, update the winner price
		if bidRec.Bidder == caller && bidRec.HashString == computedHashString {
			data, _ := winnerRec.Get(domainName)
			currentWinnerRec := data.(bidRecord)
			if price > currentWinnerRec.Price && now < currentWinnerRec.EndPriceTime {
				ufmt.Println("[PRICE]: found new winner, setting up")
				currentWinnerRec.Price = price
				currentWinnerRec.Bidder = bidRec.Bidder
				currentWinnerRec.HashString = bidRec.HashString
				currentWinnerRec.StartTime = bidRec.StartTime
				currentWinnerRec.EndCommitTime = bidRec.EndCommitTime
				currentWinnerRec.EndPriceTime = bidRec.EndPriceTime
				winnerRec.Set(domainName, currentWinnerRec)
				return "claim"
			}
		}
	}
	// if not match above case, then panic
	panic("commit price failed")
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
	data, existed := bidStorage.Get(domainName)
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
	now := time.Now().UnixMilli()
	data, existed := bidStorage.Get(domainName)
	if !existed {
		return ufmt.Errorf("endbid: invalid domain name")
	}
	bidRecList := data.([]bidRecord)
	firstBidRec := bidRecList[0]
	if now < firstBidRec.EndPriceTime {
		return ufmt.Errorf("endbid: this session can not end before the end time")
	}
	// change all state
	for _, bidRec := range bidRecList {
		bidRec.IsOpen = false
	}
	ok := bidStorage.Set(domainName, bidRecList)
	if !ok {
		return ufmt.Errorf("endbid: can not change bid record state")
	}
	// need more conditions for findTheWinner()
	findTheWinner(domainName)
	return nil
}

// register new domain with bidding process inside - if message is commit hash -> dapp need to call commit hash
// func RegisterDomain(domainName string) bidStatus {
// 	reqInfo := RequestInfo{
// 		WantedDomain: domainName,
// 		Caller:       std.PrevRealm().Addr(),
// 		Mode:         "native",
// 	}

// 	// bidStatus
// 	result := checkRegisterState(reqInfo)
// 	recordJoinedBid(domainName)
// 	// if checkState get the message of which phase this domain name belongs to, then return the status
// 	return result
// }

// func checkRegisterState(req RequestInfo) bidStatus {
// 	var bStt bidStatus
// 	// check if domain name is regex valid
// 	if !isValidDomain(req.WantedDomain) {
// 		panic("invalid domain name")
// 	}
// 	// check if dName is registered
// 	if AlreadyRegistered(req.WantedDomain) {
// 		panic("domain name already registered")
// 	}
// 	// changelogs v2: we are using sealed bidding now
// 	// check if a bidding session is openning -> append new commit hash into record list
// 	// both existed or not we open new bidding session
// 	// for now we return a signal for dapps / service to know what to do next
// 	isExisted, isOpen := checkBiddingState(req.WantedDomain)
// 	if isExisted && isOpen {
// 		// return commit hash signal for dapps
// 		bStt.CurrentStatus = AppendBiddingSession
// 		bStt.ActionCode = CommitHashPhase
// 		return bStt
// 	}

// 	// create new session
// 	if !isExisted {
// 		bStt.CurrentStatus = NewBiddingSession
// 		bStt.ActionCode = CommitHashPhase
// 		return bStt
// 	}

// 	// not found in register repository but also not found in Bidding Record -> panic("error somewhere :D")
// 	panic(ufmt.Errorf("should not happend"))
// 	return bStt
// }

// // open a bidding session
// func openBiddingSession(domainName string, dur time.Duration) string {
// 	now := time.Now()
// 	bidRec := bidRecord{
// 		DomainName: domainName,
// 		StartTime:  now,
// 	}
// 	bidRecList := []bidRecord{bidRec}
// 	ok := bidStorage.Set(domainName, bidRecList)
// 	if !ok {
// 		panic("can not open bidding session")
// 	}
// 	return "created bidding session"
// }

func checkBiddingState(dName string) (isExisted bool, isOpen bool) {
	data, existed := bidStorage.Get(dName)
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
	data, existed := bidStorage.Get(dName)
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
	// ufmt.Println("send from contract ", bankerContract.String(), " to admin ", admin.String(), " amount: ", ugnotCoin)
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
