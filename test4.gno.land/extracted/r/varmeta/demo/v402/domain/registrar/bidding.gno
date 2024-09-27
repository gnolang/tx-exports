package registrar

import (
	"std"
	"strconv"
	"time"

	"gno.land/p/demo/ufmt"
	// "gno.land/p/demo/mux"
	"gno.land/p/demo/avl"
)

// I want to redesign this codebase

// all keys are domainName
var bidStorages avl.Tree // dName <- []bidRecV2

// record new joined bid
func record2Storage(domainName string) {
	caller := std.GetOrigCaller()
	now := time.Now().UnixMilli()
	newRec := bidRecV2{
		Bidder:     caller.String(),
		DomainName: domainName,
		StartTime:  now,
		//...
	}
	data, existed := bidStorages.Get(domainName)
	if !existed {
		bidStorages.Set(domainName, newRec)
	}
	bidRecList := data.([]bidRecV2)
	oldStartTime := bidRecList[0].StartTime
	newRec.StartTime = oldStartTime
	bidRecList = append(bidRecList, newRec)
	bidStorages.Set(domainName, bidRecList)
}

// GetJoinedBid returns the status of an user's joined bid session information
func GetJoinedBid(caller string) []bidStatus {
	dNameList := []string{}
	// Iterate the bidStorages, which domainName has Bidder == caller -> take domainNames
	bidStorages.Iterate("", "", func(key string, value interface{}) bool {
		dataList := value.([]bidRecV2)
		for _, rec := range dataList {
			if rec.Bidder == caller {
				ufmt.Println("key to append: ", key)
				dNameList = append(dNameList, key)
			}
		}
		return false
	})
	ufmt.Println("len: ", len(dNameList))
	// after get dNameList of a caller, we check status of each dName
	listStatus := []bidStatus{}
	for _, dName := range dNameList {
		stt := GetCurrentStatus(dName, caller)
		// get the time stamp in [0] element and assign it to status
		data, _ := bidStorages.Get(dName)
		bidRec := data.([]bidRecV2)[0]

		singleStt := bidStatus{
			DomainName:    dName,
			Status:        stt,
			EndCommitTime: bidRec.EndCommitTime,
			EndPriceTime:  bidRec.EndPriceTime,
		}
		listStatus = append(listStatus, singleStt)
	}
	ufmt.Println("len of list status: ", len(listStatus))
	return listStatus
}

/*
	I want the CommitHash and CommitPrice will change the status of the record, by this way, we can detect
	the current state of a bidding session for each user
*/

// GetCurrentStatus returns the status of the bidding session about a domain name. This func requires caller to determine in case Committed or not (hash or price)
func GetCurrentStatus(domainName string, caller string) string {
	// if there is record in joinedBid -> user joined
	// check for tine.Now() and startTime
	now := time.Now().UnixMilli()
	// if domain name is owned already
	owner := GetOwner(domainName)
	if owner != "" {
		return "owned by " + owner.String()
	}
	// find the record
	data, existed := bidStorages.Get(domainName)
	if !existed {
		// no record in bidRec yet -> not Committed -> check if user started auction or not - if yes: new auction
		return "domain name is free"
	}
	recList := data.([]bidRecV2)
	// find the record of the caller
	for _, rec := range recList {
		// Auction closed
		if rec.EndPriceTime < now && owner != ""{
			return "closed"
		}

		switch {
		// Waiting for hash commitment
		case !rec.IsCommittedHash && !rec.IsCommittedPrice && rec.StartTime < now && rec.EndCommitTime > now:
			return "waiting hash"

		// Committed hash
		case rec.IsCommittedHash && !rec.IsCommittedPrice && rec.StartTime < now && rec.EndCommitTime > now:
			return "committed hash"

		// Waiting for price commitment
		case rec.IsCommittedHash && !rec.IsCommittedPrice && rec.EndCommitTime < now && rec.EndPriceTime > now:
			return "waiting price"

		// Committed price
		case rec.IsCommittedHash && rec.IsCommittedPrice && rec.EndCommitTime < now && rec.EndPriceTime > now:
			return "committed price"

		// Winner claiming domain
		case rec.IsCommittedHash && rec.IsCommittedPrice && rec.IsWinner && rec.EndPriceTime < now:
			return rec.Bidder + " is claiming domain name: " + domainName

		// Missed hash commitment deadline
		case !rec.IsCommittedHash && rec.EndCommitTime < now:
			return "waiting for hash"
		}
	}

	return "undefined"
}

// CommitHash consumes off-chain calculated hash string and the domain name that user want
func CommitHash(domainName, hashString string) string {
	caller := std.GetOrigCaller()

	// use now as int64 representation of time.Now()
	now := time.Now().UnixMilli()

	// update the bid record
	data, existed := bidStorages.Get(domainName)

	// if not existed -> create new record
	if !existed {
		// for further getStatus
		// record2Storage(domainName)

		var bidRec bidRecV2
		endCommitTime := now + defaultCommitHashTime.Milliseconds()
		endPriceTime := endCommitTime + defaultCommitPriceTime.Milliseconds()
		ufmt.Println("[HASH]: request at: ", time.UnixMilli(now))
		ufmt.Println("[HASH]: endCommitTime: ", time.UnixMilli(endCommitTime))
		ufmt.Println("[HASH]: endPriceTime: ", time.UnixMilli(endPriceTime))
		bidRec = bidRecV2{
			DomainName:       domainName,
			Bidder:           caller.String(),
			HashString:       hashString,
			StartTime:        now,
			EndCommitTime:    endCommitTime,
			EndPriceTime:     endPriceTime,
			IsCommittedHash:  true,
			IsCommittedPrice: false,
			IsWinner:         true,
			Price:            0,
		}
		bidRecList := []bidRecV2{bidRec}
		bidStorages.Set(domainName, bidRecList)

		// charge fee
		chargeFee(fee.BidJoinFee, std.Address(caller))
		return "new session"
	}
	// if existed
	bidRecList := data.([]bidRecV2)
	startTime := bidRecList[0].StartTime
	oldEndCommitTimeUnix := bidRecList[0].EndCommitTime
	oldEndPriceTimeUnix := bidRecList[0].EndPriceTime
	if now > oldEndCommitTimeUnix {
		// now := time.Now().UnixMilli()
		// ufmt.Println("[HASH]: now: ", time.UnixMilli(now))
		panic("[HASH]: can not commit hash anymore")
	}
	for _, bR := range bidRecList {
		if bR.Bidder == caller.String() {
			panic("[HASH]: you already Committed hash")
		}
	}

	bidRec := bidRecV2{
		DomainName:       domainName,
		HashString:       hashString,
		Bidder:           caller.String(),
		StartTime:        startTime,
		EndCommitTime:    oldEndCommitTimeUnix,
		EndPriceTime:     oldEndPriceTimeUnix,
		IsCommittedHash:  true,
		IsCommittedPrice: false,
		IsWinner:         false,
	}
	// append the list, set it to storage
	bidRecList = append(bidRecList, bidRec)
	// Save record
	bidStorages.Set(domainName, bidRecList)
	// charge commit hash fee
	chargeFee(fee.BidJoinFee, caller)
	return "existed"
}

// for now we dont use panic because this will cause the permanent time.Now() stuck. IDK why // XXX fix me
// CommitPrice consumes price and secret string that user used in calculating hash string from off-chain. This will re-calculate the hashstring and compare with the one Committed before
func CommitPrice(price int64, secret string, domainName string) string {
	// compute the hash string, compare to saved hash string in record
	// use int64 representation of time.Now()
	now := time.Now().UnixMilli()
	ufmt.Println("[PRICE]: request at: ", time.UnixMilli(now))
	joinedString := secret + strconv.Itoa(int(price))
	computedHashString := Get256String(joinedString)
	caller := std.GetOrigCaller()
	data, existed := bidStorages.Get(domainName)
	if !existed {
		panic("[PRICE]: domain name is invalid")
	}
	bidRecList := data.([]bidRecV2)
	// winnerRec.Set(domainName, bidRecList[len(bidRecList)-1])
	// ufmt.Println("[PRICE] current winner set to: ", bidRecList[len(bidRecList)-1].Bidder.String())

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
	// detect current winner by index and address
	currentWinnerInx, currentWinnerRec := findTheWinner(domainName)

	// search for the corresponding hash
	for index, bidRec := range bidRecList {
		// panic because wrong price or wrong secret string
		if bidRec.Bidder == caller.String() && bidRec.HashString != computedHashString {
			panic("[PRICE]: invalid hash string")
		}
		// found it, update the price
		if bidRec.Bidder == caller.String() && bidRec.HashString == computedHashString {
			// update record

			// find the winner
			if price > currentWinnerRec.Price && now < currentWinnerRec.EndPriceTime {
				ufmt.Println("[PRICE]: found new winner, setting up")
				newRec := bidRecV2{
					DomainName:       domainName,
					Price:            price,
					IsCommittedHash:  true,
					IsCommittedPrice: true,
					IsWinner:         true,
					StartTime:        currentWinnerRec.StartTime,
					EndCommitTime:    currentWinnerRec.EndCommitTime,
					EndPriceTime:     currentWinnerRec.EndPriceTime,
					Bidder:           caller.String(),
				}

				// need to change old winner to false
				bidRecList[currentWinnerInx].IsWinner = false
				bidRecList[currentWinnerInx].IsCommittedPrice = true
				// save records
				bidRecList[index] = newRec
				bidStorages.Set(domainName, bidRecList)
				return "claim"
			}
		} else {
			ufmt.Println("you are not in bidding list")
			return "you are not in bidding list"
		}
	}
	// if not match above case, then panic
	panic("commit price failed")
}

// GetCurrentWinner shows the current highest price user
func GetCurrentWinner(domainName string) bidRecV2 {
	data, existed := bidStorages.Get(domainName)
	if !existed {
		panic("no winner yet")
	}
	list := data.([]bidRecV2)
	for _, bidRec := range list {
		if bidRec.IsWinner {
			return bidRec
		}
	}
	// panic - should not happend
	return bidRecV2{}
}

// find the highest bid in session - incase everyone Committed price
// in old flow, we need to find the winner by retrievaling the bidStorage
func findTheWinner(domainName string) (index int, winnerBid bidRecV2) {
	data, existed := bidStorages.Get(domainName)
	if !existed {
		panic("invalid domain name")
	}
	index = 0
	bidRecList := data.([]bidRecV2)
	winnerBid = bidRecList[0]
	for i, bidRec := range bidRecList {
		if bidRec.Price > winnerBid.Price {
			winnerBid = bidRec
			index = i
		}
	}
	return index, winnerBid
}

// get all the price list that joined the bid for displaying in dapp
func GetRecords(dName string) []bidRecV2 {
	data, existed := bidStorages.Get(dName)
	if !existed {
		panic("should not")
	}
	return data.([]bidRecV2)
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
	if !bidStorages.Has(domainName) {
		panic("claim: invalid domain name")
	}
	caller := std.GetOrigCaller()
	_, winner := findTheWinner(domainName)
	if caller.String() != winner.Bidder {
		panic("only winner can claim")
	}
	requestInfo := RequestInfo{
		WantedDomain: domainName,
		Caller:       caller,
		Mode:         "native",
	}
	result := executeRegister(requestInfo)
	if !result.Success {
		panic(result.ResultDetails.Error())
	}
	// register done. Now charge the fee
	chargeFee(winner.Price, caller)
	feeProcess(requestInfo)
	return true
}

// expose winner price - amount of fee that user need to pay in Claim phase
func GetWinnerPrice(dName string) int64 {
	rec := GetCurrentWinner(dName)
	return rec.Price
}
