package sbid

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"time"

	"gno.land/p/demo/avl"
)

type Bid struct {
	Infos        *avl.Tree // caller <- *bidInfo because the *Bid point to the current session, so list of key is list of callers
	EndHashTime  int64
	EndPriceTime int64
	StartTime    int64
}

type bidInfo struct {
	BidObject        string
	Bidder           string
	HashString       string
	Price            int64
	IsCommittedHash  bool
	IsCommittedPrice bool
	IsWinner         bool
}

type BidStatus struct {
	BidObject    string
	Status       string
	EndHashTime  int64
	EndPriceTime int64
	ActiveUsers  int64
}

/*
the flow should be:
this package manages list of bidding session. Store by key: domain name and value is: bidSessionInfo
this structure (bidSesionInfo) includes 2 *avl.Tree.
1 - key: bidID mapping to value is: that ID bid info
2 - key: address (caller string) mapping to value is: ID list
-> if you want to find a joined list, just take value from 2nd tree, take all value with these keys in the first tree :D
lets say:

	you have rootTree: dname <- bidSessionInfo {
		IDInfoTree: ID <- bidInfo // update these infos when there is something is committed
		CallerID: caller <- []ID // every time you join in new bid, this is updated
	}

if you trigger new bid, check if there is existed bid or not

	1: -> return the current bid with key dName
	2: -> return the new instance of bid with key dName
*/

// SetTime sets the start time, end time for each phase of commit
func (b *Bid) SetTime(startTime, endHashTime, endPriceTime int64) {
	b.StartTime = startTime
	b.EndHashTime = endHashTime
	b.EndPriceTime = endPriceTime
}

// set new bid record into the root storage -> need function to take the root storage
func (b *Bid) recordNewBid(domainName string) bool {
	return true
}

// GetStatus return status list of all joined session by a caller -> implement on realm
// on this function, just check status of the session that caller joined
func (b *Bid) GetStatus(domainName string, caller string) BidStatus {
	// return status
	bStt := BidStatus{}

	infoData, ext := b.Infos.Get(caller)
	if !ext {
		bStt.Status = "free"
		return bStt
	}
	info := infoData.(*bidInfo)
	stt := b.getStatusFromInfo(domainName, *info)
	bStt.BidObject = domainName
	bStt.Status = stt
	bStt.EndHashTime = b.EndHashTime
	bStt.EndPriceTime = b.EndPriceTime
	bStt.ActiveUsers = int64(b.Infos.Size())
	return bStt
}

// get current status of a bid info in the bidding session that caller joined
func (b *Bid) getStatusFromInfo(object string, info bidInfo) string {
	now := time.Now().UnixMilli()

	// Check if the auction is closed then return winner ?
	if now > b.EndPriceTime {
		if info.IsCommittedPrice {
			winner := b.GetCurrentWinnerInfo()
			if !winner.IsWinner {
				return "no winner yet"
			}
			return winner.Bidder + " is claiming " + object
		}
		return "close"
	}

	switch {
	// Waiting for hash commitment
	case !info.IsCommittedHash && !info.IsCommittedPrice && b.StartTime <= now && b.EndHashTime > now:
		return "waiting hash"

	// Committed hash
	case info.IsCommittedHash && !info.IsCommittedPrice && b.StartTime <= now && b.EndHashTime > now:
		return "committed hash"

	// Waiting for price commitment
	case info.IsCommittedHash && !info.IsCommittedPrice && b.EndHashTime <= now && b.EndPriceTime > now:
		return "waiting price"

	// Committed price
	case info.IsCommittedHash && info.IsCommittedPrice && b.EndHashTime <= now && b.EndPriceTime > now:
		return "committed price"

	// Winner claiming
	case info.IsCommittedHash && info.IsCommittedPrice && !info.IsWinner && b.EndPriceTime <= now:
		winner := b.GetCurrentWinnerInfo()
		if winner.Bidder == "" {
			return "no winner yet"
		}
		return winner.Bidder + " is claiming " + object

	// Missed hash commitment deadline
	case !info.IsCommittedHash && b.EndHashTime <= now:
		return "waiting for hash"

	default:
		return "undefined"
	}
}

func (b *Bid) GetCurrentWinnerInfo() bidInfo {
	winner := bidInfo{}
	b.Infos.Iterate("", "", func(key string, value interface{}) bool {
		bid := value.(*bidInfo)
		if bid.IsWinner {
			winner = *bid
			return true
		}
		return false
	})
	return winner
}

// logic for handle new price commit - check winner
func (b *Bid) calculateAndRecordWinner(currentCaller string, newRecord *bidInfo) string {
	// need to find the list of caller that refer to a domain. information is included inside the b *Bid
	// update logs: not need to get the list anymore, just ->
	// iterate over the list and find out the winner
	if b.Infos.Size() == 1 {
		// update winner now
		newRecord.IsWinner = true
		b.Infos.Set(currentCaller, newRecord)
		return "update first element - winner"
	}
	// if there is more than 1 joined bid -> set first commit price is winner then check new winner
	// before we iterate the list, we need to set a winner?

	// simple solutions: take the list of bidInfo, find the winner, set it. Next time check for IsWinner
	infoList := []*bidInfo{}
	b.Infos.Iterate("", "", func(key string, value interface{}) bool {
		bidInf := value.(*bidInfo)
		infoList = append(infoList, bidInf)
		return false
	})
	// find max of bidInfo.Price
	maxIndex := 0
	maxPrice := infoList[0].Price
	for index, bif := range infoList {
		if bif.Price > maxPrice {
			maxPrice = bif.Price
			maxIndex = index
		}
	}
	// newRecord is winner _. not need to update old record
	if maxPrice < newRecord.Price {
		newRecord.IsWinner = true
		b.Infos.Set(newRecord.Bidder, newRecord)
		loserBid := infoList[maxIndex]
		loserBid.IsWinner = false
		b.Infos.Set(loserBid.Bidder, loserBid)
	} else if maxPrice >= newRecord.Price {
		// record new entry and update old winner
		newRecord.IsWinner = false
		winnerBid := infoList[maxIndex]
		winnerBid.IsWinner = true
		b.Infos.Set(currentCaller, newRecord)
		b.Infos.Set(winnerBid.Bidder, winnerBid)
	}
	return "update winner for " + currentCaller
}

// need 2 phases. these functions are for the commit hash string and commit the details
func (b *Bid) CommitHash(domainName string, hashString string, caller string) string {
	// TODO: Check for time of each phases?
	now := time.Now().UnixMilli()
	if now > b.EndHashTime {
		return "can not commit hash anymore"
	}
	// check if caller is committed hash
	if b.Infos.Has(caller) {
		return "you already committed hash"
	}
	// new bid
	newBidInfo := bidInfo{
		BidObject:        domainName,
		Bidder:           caller,
		HashString:       hashString,
		IsCommittedHash:  true,
		IsCommittedPrice: false,
		IsWinner:         false,
	}
	// set to info storage
	b.Infos.Set(caller, &newBidInfo)
	// TODO: Charge fee ?
	return "committed hash"
}

// basic logic first
func (b *Bid) CommitPrice(domainName string, price int64, secret string, caller string) string {
	if time.Now().UnixMilli() > b.EndPriceTime {
		return "can not commit price and secret anymore"
	}
	if time.Now().UnixMilli() <= b.EndHashTime {
		return "price phase is not started"
	}
	// check in bidInfos list
	data, ext := b.Infos.Get(caller)
	if !ext {
		return "you are not in the info list"
	}
	info := data.(*bidInfo)
	if !info.IsCommittedHash {
		return "not committed hash yet"
	}
	if info.IsCommittedPrice {
		return "can not commit price twice"
	}
	hashCalculated := calculateHS(price, secret)
	if hashCalculated != info.HashString {
		return "invalid secret key or price"
	}
	if info.IsCommittedHash && hashCalculated == info.HashString && !info.IsCommittedPrice {
		info.IsCommittedPrice = true
		info.Price = price
		info.IsWinner = false
		// setup new record

		b.calculateAndRecordWinner(caller, info)
		return "committed price"
	}

	return "undefined"
}

// calculate hash string from secret+price
func calculateHS(price int64, secret string) string {
	input := secret + strconv.Itoa(int(price))
	data := []byte(input)
	hashed := sha256.Sum256(data)
	hashedBytes := hashed[:]
	return hex.EncodeToString(hashedBytes)
}

/*
	redegisn the flow with this idea:
	this is base package, use realm to really serialize the data and logic checks

*/
