package admin

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"

const (
	MigrationResearchExpectedExplorerURL              = "https://pre-migration.akkadia.land"
	MigrationResearchExpectedFaucetTargetAmount int64 = 1000000
)

var (
	MigrationResearchExpectedPendingAdmin = address("g1lg8w6keklpfyfzyure645ethfuahfgrhmlg8cu")
	MigrationResearchExpectedFeeCollector = address("g1rdnjhf88gtpjr4l9jcqyrg6zkncw0tnjuh0t3a")
	MigrationResearchExpectedProtocol     = address("g19cw6xhwak0k40ayphn2d37l26he972vtunkddg")
	MigrationResearchExpectedOperator     = address("g1x8l886kqzdlqt8v0znrj89mhas0h242caseqe9")
)

var (
	admin              address
	pendingAdmin       address
	explorerURL        string
	feeCollectorAddr   address
	protocolAddr       address
	frozen             bool
	faucetTargetAmount int64
	operatorAddrs      map[address]bool = make(map[address]bool)
)

func IsAdmin(addr address) bool {
	return addr == admin
}

func SetExplorerURL(cur realm, url string) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	explorerURL = url
}

func SetFeeCollector(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	feeCollectorAddr = addr
}

func SetProtocol(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	protocolAddr = addr
}

func SetOperator(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	operatorAddrs[addr] = true
}

func UnsetOperator(cur realm, addr address) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	delete(operatorAddrs, addr)
}

func SetFaucetTargetAmount(cur realm, amount int64) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	faucetTargetAmount = amount
}

func GetFaucetTargetAmount() int64 {
	return faucetTargetAmount
}
