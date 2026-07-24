package multisig

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/r/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/reputation"
)

type Proposal struct {
	id          int
	description string
	to          address
	amount      int64
	executed    bool
	approvals   avl.Tree
	approveCnt  int
}

var (
	owners      avl.Tree
	ownerCount  int
	threshold   int
	initialized bool
	deployer    address
	proposals   avl.Tree
	nextID      int
)

func init() {
	deployer = unsafe.OriginCaller()
	nextID = 1
}

func Setup(cur realm, owner1 address, owner2 address, owner3 address, thresh int) {
	caller := cur.Previous().Address()
	if caller != deployer {
		panic("only deployer can run setup")
	}
	if initialized {
		panic("already initialized")
	}
	if thresh < 1 || thresh > 3 {
		panic("invalid threshold")
	}
	owners.Set(owner1.String(), true)
	owners.Set(owner2.String(), true)
	owners.Set(owner3.String(), true)
	ownerCount = 3
	threshold = thresh
	initialized = true
}

func assertOwner(caller address) {
	if !initialized {
		panic("multisig not initialized")
	}
	_, exists := owners.Get(caller.String())
	if !exists {
		panic("caller is not an owner")
	}
}

func Propose(cur realm, description string, to address, amount int64) int {
	caller := cur.Previous().Address()
	assertOwner(caller)

	id := nextID
	nextID++
	p := &Proposal{
		id:          id,
		description: description,
		to:          to,
		amount:      amount,
	}
	proposals.Set(strconv.Itoa(id), p)
	return id
}

func Approve(cur realm, proposalID int) {
	caller := cur.Previous().Address()
	assertOwner(caller)

	raw, exists := proposals.Get(strconv.Itoa(proposalID))
	if !exists {
		panic("proposal does not exist")
	}
	p := raw.(*Proposal)
	if p.executed {
		panic("proposal already executed")
	}
	_, alreadyApproved := p.approvals.Get(caller.String())
	if alreadyApproved {
		panic("already approved")
	}
	p.approvals.Set(caller.String(), true)
	p.approveCnt++
}

func Execute(cur realm, proposalID int) {
	raw, exists := proposals.Get(strconv.Itoa(proposalID))
	if !exists {
		panic("proposal does not exist")
	}
	p := raw.(*Proposal)
	if p.executed {
		panic("proposal already executed")
	}
	if p.approveCnt < threshold {
		panic("not enough approvals")
	}
	p.executed = true

	bkr := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bkr.SendCoins(cur.Address(), p.to, chain.Coins{{Denom: "ugnot", Amount: p.amount}})

	p.approvals.Iterate("", "", func(key string, value interface{}) bool {
		reputation.AddPoints(cross(cur), address(key), "multisig_approval", 10)
		return false
	})
}

func TreasuryAddress() address {
	return unsafe.CurrentRealm().Address()
}

func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("Multisig Treasury\n")
	sb.WriteString("Initialized: " + strconv.FormatBool(initialized) + "\n")
	if initialized {
		sb.WriteString("Owners: " + strconv.Itoa(ownerCount) + " | Threshold: " + strconv.Itoa(threshold) + "\n")
	}
	sb.WriteString("\n")
	proposals.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Proposal)
		status := "pending"
		if p.executed {
			status = "executed"
		}
		sb.WriteString("Proposal #" + strconv.Itoa(p.id) + ": " + p.description +
			" | to: " + p.to.String() +
			" | amount: " + strconv.FormatInt(p.amount, 10) +
			" | approvals: " + strconv.Itoa(p.approveCnt) + "/" + strconv.Itoa(threshold) +
			" [" + status + "]\n")
		return false
	})
	return sb.String()
}
