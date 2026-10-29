package zdex

import (
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	admin        address
	pendingAdmin address
	paused       bool
	pools        avl.Tree
	pos     avl.Tree
	orders  avl.Tree
	vests   avl.Tree
	tokens  avl.Tree
	scores  avl.Tree
	modules avl.Tree // surface name -> pkg path; empty means this hub
	farms    avl.Tree // trusted farm realm address -> true
	farmPay  avl.Tree // farm address -> prepaid ugnot
	listings avl.Tree // symbol -> *Listing
	nextOrd  seqid.ID

	epoch        uint64
	epochEnd     int64
	epochPts     int64
	epochPot     int64
	epochBlocks  int64
	feeShareBps  int64
	closedID     uint64
	closedPts    int64
	closedPot    int64
)

func init(cur realm) {
	admin = cur.Previous().Address()
	epochBlocks = defaultEpochBlocks
	feeShareBps = defaultFeeShareBps
}

func thisAddr() address {
	return unsafe.CurrentRealm().Address()
}

func thisPkg() string {
	return unsafe.CurrentRealm().PkgPath()
}

func height() int64 {
	return runtime.ChainHeight()
}

func mustOwner(cur realm) {
	if cur.Previous().Address() != admin {
		panic("zdex: admin only")
	}
}

func assertNotPaused() {
	if paused {
		panic("zdex: paused")
	}
}

func poolIDFor(symbol string) string {
	return nativeDenom + "|" + symbol
}

func pairID(a, b string) string {
	require(a != "" && b != "" && a != b, "zdex: pair")
	if a < b {
		return a + "|" + b
	}
	return b + "|" + a
}

func isQuoteTok(p *Pool, tok string) bool {
	if p.QuoteSym == "" {
		return tok == nativeDenom || tok == "GNOT"
	}
	return tok == p.QuoteSym || tok == p.QuoteTok
}

func isBaseTok(p *Pool, tok string) bool {
	return tok == p.Symbol || tok == p.Token
}

func posKey(poolID string, owner address) string {
	return poolID + "/" + owner.String()
}

func vestKey(symbol string, owner address) string {
	return symbol + "/" + owner.String()
}

func getPool(id string) *Pool {
	v := pools.Get(id)
	if v == nil {
		panic("zdex: pool not found")
	}
	return v.(*Pool)
}

func tryPool(id string) *Pool {
	v := pools.Get(id)
	if v == nil {
		return nil
	}
	return v.(*Pool)
}

func getPos(poolID string, owner address) *Position {
	v := pos.Get(posKey(poolID, owner))
	if v == nil {
		return nil
	}
	return v.(*Position)
}

func setPos(poolID string, owner address, lp int64) {
	k := posKey(poolID, owner)
	if lp == 0 {
		pos.Remove(k)
		return
	}
	pos.Set(k, &Position{LP: lp})
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
