// multisig — Multi-signature wallet (Gno Safe)
// Requires M-of-N signatures to execute transactions
// 10 signers, 7 required threshold
package multisig

import (
	"strconv"
	"strings"

	"chain/runtime"
)

// Tx represents a pending multi-sig transaction
type Tx struct {
	ID         int
	To         string  // recipient address
	Amount     int64   // amount in ugnot
	Proposer   string  // who submitted
	Approved   map[string]bool  // who approved
	Executed   bool
	CreatedBlock int64
}

var (
	transactions map[int]*Tx
	nextTxID     int
	signers      map[string]bool
	threshold    int  // signatures needed
	totalSigners int
)

func init() {
	transactions = make(map[int]*Tx)
	nextTxID = 1
	signers = make(map[string]bool)
	threshold = 7
	totalSigners = 0
}

// === Signer Management ===

// AddSigner adds a new signer. Only existing signers can add.
func AddSigner(cur realm, signer string) {
	caller := cur.Previous().Address().String()
	if totalSigners > 0 && !signers[caller] {
		panic("only existing signers can add new signers")
	}
	if signers[signer] {
		panic("already a signer")
	}
	signers[signer] = true
	totalSigners++
}

// IsSigner checks if address is a signer
func IsSigner(addr string) bool {
	return signers[addr]
}

// SignerCount returns total signers
func SignerCount() int {
	return totalSigners
}

// GetThreshold returns required signatures
func GetThreshold() int {
	return threshold
}

// SetThreshold updates the threshold. Only signers can do this.
func SetThreshold(cur realm, newThreshold int) {
	caller := cur.Previous().Address().String()
	if !signers[caller] {
		panic("only signers can update threshold")
	}
	if newThreshold < 1 || newThreshold > totalSigners {
		panic("invalid threshold")
	}
	threshold = newThreshold
}

// === Transaction Lifecycle ===

// SubmitTx proposes a new transaction to send ugnot
func SubmitTx(cur realm, to string, amount int64) int {
	caller := cur.Previous().Address().String()
	if !signers[caller] {
		panic("only signers can submit transactions")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}

	id := nextTxID
	nextTxID++

	transactions[id] = &Tx{
		ID:           id,
		To:           to,
		Amount:       amount,
		Proposer:     caller,
		Approved:     make(map[string]bool),
		Executed:     false,
		CreatedBlock: runtime.ChainHeight(),
	}

	// Proposer auto-approves their own submission
	transactions[id].Approved[caller] = true
	return id
}

// ApproveTx signs/approves a pending transaction
func ApproveTx(cur realm, txID int) int {
	caller := cur.Previous().Address().String()
	if !signers[caller] {
		panic("only signers can approve")
	}

	tx, ok := transactions[txID]
	if !ok {
		panic("transaction not found")
	}
	if tx.Executed {
		panic("transaction already executed")
	}
	if tx.Approved[caller] {
		panic("already approved")
	}

	tx.Approved[caller] = true
	return len(tx.Approved)
}

// ExecuteTx executes the transaction if threshold met
func ExecuteTx(cur realm, txID int) string {
	caller := cur.Previous().Address().String()
	if !signers[caller] {
		panic("only signers can execute")
	}

	tx, ok := transactions[txID]
	if !ok {
		panic("transaction not found")
	}
	if tx.Executed {
		panic("already executed")
	}

	approvalCount := len(tx.Approved)
	if approvalCount < threshold {
		panic("insufficient approvals: " + strconv.Itoa(approvalCount) + "/" + strconv.Itoa(threshold))
	}

	// Mark as executed
	// In production, this would use chain/banker to actually send ugnot
	tx.Executed = true
	return "executed: sent " + strconv.FormatInt(tx.Amount, 10) + "ugnot to " + tx.To
}

// === Query Functions ===

// GetTx returns transaction details
func GetTx(id int) (string, int64, string, int, bool, int64) {
	tx := transactions[id]
	return tx.To, tx.Amount, tx.Proposer, len(tx.Approved), tx.Executed, tx.CreatedBlock
}

// GetApprovals returns list of approvers
func GetApprovals(id int) []string {
	tx := transactions[id]
	approvers := make([]string, 0, len(tx.Approved))
	for addr := range tx.Approved {
		approvers = append(approvers, addr)
	}
	return approvers
}

// PendingTxCount returns number of pending (non-executed) txs
func PendingTxCount() int {
	count := 0
	for _, tx := range transactions {
		if !tx.Executed {
			count++
		}
	}
	return count
}

// TotalTxCount returns total transactions
func TotalTxCount() int {
	return len(transactions)
}

// === Render ===

func Render(_ string) string {
	b := strings.Builder{}
	b.WriteString("# Multi-sig Wallet (Gno Safe)\n\n")
	b.WriteString("## Config\n")
	b.WriteString("- Signers: " + strconv.Itoa(totalSigners) + "\n")
	b.WriteString("- Threshold: " + strconv.Itoa(threshold) + " signatures required\n")
	b.WriteString("- Pending TXs: " + strconv.Itoa(PendingTxCount()) + "\n\n")
	b.WriteString("## Transactions\n")
	for id, tx := range transactions {
		status := "pending"
		if tx.Executed {
			status = "executed"
		}
		b.WriteString("### TX #" + strconv.Itoa(id) + "\n")
		b.WriteString("- To: " + tx.To + "\n")
		b.WriteString("- Amount: " + strconv.FormatInt(tx.Amount, 10) + " ugnot\n")
		b.WriteString("- Proposer: " + tx.Proposer + "\n")
		b.WriteString("- Approvals: " + strconv.Itoa(len(tx.Approved)) + "/" + strconv.Itoa(threshold) + "\n")
		b.WriteString("- Status: " + status + "\n\n")
	}
	return b.String()
}
