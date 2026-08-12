package manager

const (
	AdminRole  RoleId = 0
	PublicRole RoleId = 1<<64 - 1 // uint64 max

	// MinSetback is the minimum setback for a grant delay change (5 days).
	// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L164-L166
	// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1076-L1080
	MinSetback uint32 = 5 * 24 * 60 * 60
)
