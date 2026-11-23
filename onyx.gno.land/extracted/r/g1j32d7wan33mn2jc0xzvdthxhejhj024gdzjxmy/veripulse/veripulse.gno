package veripulse

import (
	"std"
	"strconv"
	"strings"
	"time"
)

// TaskStatus defines state of an escrow audit task
type TaskStatus string

const (
	StatusOpen      TaskStatus = "OPEN"
	StatusSubmitted TaskStatus = "SUBMITTED"
	StatusVerified  TaskStatus = "VERIFIED"
	StatusDisputed  TaskStatus = "DISPUTED"
	StatusRefunded  TaskStatus = "REFUNDED"
)

// EscrowTask encapsulates the deterministic AI execution contract
type EscrowTask struct {
	ID             string     `json:"id"`
	Client         std.Address `json:"client"`
	Agent          std.Address `json:"agent"`
	Auditor        std.Address `json:"auditor"`
	Title          string     `json:"title"`
	Description    string     `json:"description"`
	BountyUgnot    int64      `json:"bounty_ugnot"`
	ExpectedHash   string     `json:"expected_hash"`
	SubmittedHash  string     `json:"submitted_hash"`
	ModelMetadata  string     `json:"model_metadata"`
	AuditorNotes   string     `json:"auditor_notes"`
	Status         TaskStatus `json:"status"`
	CreatedAt      int64      `json:"created_at"`
	SubmittedAt    int64      `json:"submitted_at"`
	ResolvedAt     int64      `json:"resolved_at"`
}

var (
	tasks       []*EscrowTask
	taskCount   int64
	adminAddr   std.Address
	totalVolume int64
)

func init() {
	adminAddr = std.Address("g1j32d7wan33mn2jc0xzvdthxhejhj024gdzjxmy")
	tasks = make([]*EscrowTask, 0)
	taskCount = 0
	totalVolume = 0
}

// CreateTask initializes a new escrow task locking GNOT bounty
func CreateTask(title string, description string, expectedHash string, auditorAddr string) string {
	caller := std.GetOrigCaller()
	send := std.GetOrigSend()
	bounty := send.AmountOf("ugnot")

	if bounty <= 0 {
		panic("VeriPulse: bounty deposit must be greater than 0 ugnot")
	}

	trimmedTitle := strings.TrimSpace(title)
	if trimmedTitle == "" {
		panic("VeriPulse: task title cannot be empty")
	}

	var auditor std.Address
	if auditorAddr != "" {
		auditor = std.Address(auditorAddr)
	} else {
		auditor = adminAddr
	}

	taskCount++
	taskID := "task-" + strconv.FormatInt(taskCount, 10)
	now := time.Now().Unix()

	task := &EscrowTask{
		ID:            taskID,
		Client:        caller,
		Auditor:       auditor,
		Title:         trimmedTitle,
		Description:   strings.TrimSpace(description),
		BountyUgnot:   bounty,
		ExpectedHash:  strings.ToLower(strings.TrimSpace(expectedHash)),
		Status:        StatusOpen,
		CreatedAt:     now,
	}

	tasks = append(tasks, task)
	totalVolume += bounty

	return taskID
}

// SubmitProof allows an AI agent to submit deterministic execution proof
func SubmitProof(taskID string, proofHash string, modelMetadata string) {
	caller := std.GetOrigCaller()
	task := findTask(taskID)
	if task == nil {
		panic("VeriPulse: task not found: " + taskID)
	}

	if task.Status != StatusOpen {
		panic("VeriPulse: task is not in OPEN status")
	}

	cleanedHash := strings.ToLower(strings.TrimSpace(proofHash))
	if len(cleanedHash) != 64 {
		panic("VeriPulse: invalid proof hash, must be 64-character SHA-256 hex string")
	}

	task.Agent = caller
	task.SubmittedHash = cleanedHash
	task.ModelMetadata = strings.TrimSpace(modelMetadata)
	task.SubmittedAt = time.Now().Unix()
	task.Status = StatusSubmitted
}

// VerifyAndRelease performs audit verification and deterministically transfers bounty
func VerifyAndRelease(taskID string, auditPassed bool, notes string) {
	caller := std.GetOrigCaller()
	task := findTask(taskID)
	if task == nil {
		panic("VeriPulse: task not found: " + taskID)
	}

	if task.Status != StatusSubmitted {
		panic("VeriPulse: task is not in SUBMITTED status")
	}

	// Caller must be client or designated auditor
	if caller != task.Client && caller != task.Auditor && caller != adminAddr {
		panic("VeriPulse: unauthorized verifier, only client or auditor can verify")
	}

	task.AuditorNotes = strings.TrimSpace(notes)
	task.ResolvedAt = time.Now().Unix()

	if !auditPassed {
		task.Status = StatusDisputed
		return
	}

	// If expected hash was set, submitted hash must match
	if task.ExpectedHash != "" && task.ExpectedHash != task.SubmittedHash {
		panic("VeriPulse: cryptographic mismatch between expected and submitted SHA-256 hash")
	}

	// Release locked funds to agent
	banker := std.GetBanker(std.BankerTypeRealmSend)
	payoutCoins := std.NewCoins(std.NewCoin("ugnot", task.BountyUgnot))
	banker.SendCoins(std.GetOrigPkgAddr(), task.Agent, payoutCoins)

	task.Status = StatusVerified
}

// RefundTask allows the task creator to reclaim funds if unresolved or disputed
func RefundTask(taskID string) {
	caller := std.GetOrigCaller()
	task := findTask(taskID)
	if task == nil {
		panic("VeriPulse: task not found: " + taskID)
	}

	if caller != task.Client && caller != adminAddr {
		panic("VeriPulse: unauthorized, only client can request refund")
	}

	if task.Status != StatusOpen && task.Status != StatusDisputed {
		panic("VeriPulse: cannot refund task with status " + string(task.Status))
	}

	banker := std.GetBanker(std.BankerTypeRealmSend)
	refundCoins := std.NewCoins(std.NewCoin("ugnot", task.BountyUgnot))
	banker.SendCoins(std.GetOrigPkgAddr(), task.Client, refundCoins)

	task.Status = StatusRefunded
	task.ResolvedAt = time.Now().Unix()
}

// GetTaskCount returns total tasks created
func GetTaskCount() int64 {
	return taskCount
}

// GetTotalVolume returns total ugnot processed
func GetTotalVolume() int64 {
	return totalVolume
}

// Helper to locate task by ID
func findTask(id string) *EscrowTask {
	for _, t := range tasks {
		if t.ID == id {
			return t
		}
	}
	return nil
}

// Render returns gnoweb markdown dashboard
func Render(path string) string {
	path = strings.TrimSpace(path)
	if strings.HasPrefix(path, "task/") {
		taskID := strings.TrimPrefix(path, "task/")
		t := findTask(taskID)
		if t == nil {
			return "# VeriPulse: Task Not Found\n\nNo escrow task found with ID `" + taskID + "`."
		}
		return renderTaskDetail(t)
	}

	var sb strings.Builder
	sb.WriteString("# ⚡ VeriPulse: Deterministic AI Agent Audit & Escrow Protocol\n\n")
	sb.WriteString("> **Cryptographic Trust for Autonomous AI Agents on Gno.land Onyx**\n\n")

	sb.WriteString("### 📊 Network Protocol Metrics\n")
	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("| :--- | :--- |\n")
	sb.WriteString("| **Total Escrow Tasks** | `" + strconv.FormatInt(taskCount, 10) + "` |\n")
	sb.WriteString("| **Total Volume Locked** | `" + strconv.FormatInt(totalVolume, 10) + " ugnot` (" + formatGnot(totalVolume) + " GNOT) |\n")
	sb.WriteString("| **Active Tasks** | `" + strconv.Itoa(countByStatus(StatusOpen)+countByStatus(StatusSubmitted)) + "` |\n")
	sb.WriteString("| **Verified & Paid** | `" + strconv.Itoa(countByStatus(StatusVerified)) + "` |\n")
	sb.WriteString("| **Disputed / Refunded** | `" + strconv.Itoa(countByStatus(StatusDisputed)+countByStatus(StatusRefunded)) + "` |\n\n")

	sb.WriteString("### 📜 Audit Ledger\n\n")
	if len(tasks) == 0 {
		sb.WriteString("*No tasks registered yet. Connect your Adena wallet to instantiate the first AI escrow task.*\n")
		return sb.String()
	}

	sb.WriteString("| ID | Title | Bounty | Status | AI Agent | SHA-256 Proof |\n")
	sb.WriteString("| :--- | :--- | :--- | :--- | :--- | :--- |\n")

	for _, t := range tasks {
		agentDisplay := "Pending"
		if string(t.Agent) != "" {
			agentDisplay = "`" + string(t.Agent)[:10] + "...`"
		}
		hashDisplay := "Awaiting Proof"
		if t.SubmittedHash != "" {
			hashDisplay = "`" + t.SubmittedHash[:12] + "...`"
		}

		sb.WriteString("| [" + t.ID + "](" + "task/" + t.ID + ") | " + t.Title + " | " + formatGnot(t.BountyUgnot) + " GNOT | `" + string(t.Status) + "` | " + agentDisplay + " | " + hashDisplay + " |\n")
	}

	return sb.String()
}

func renderTaskDetail(t *EscrowTask) string {
	var sb strings.Builder
	sb.WriteString("# 🔍 Task Audit Inspection: " + t.ID + "\n\n")
	sb.WriteString("### Overview\n")
	sb.WriteString("- **Title**: " + t.Title + "\n")
	sb.WriteString("- **Description**: " + t.Description + "\n")
	sb.WriteString("- **Status**: `" + string(t.Status) + "`\n")
	sb.WriteString("- **Bounty**: `" + strconv.FormatInt(t.BountyUgnot, 10) + " ugnot` (" + formatGnot(t.BountyUgnot) + " GNOT)\n")
	sb.WriteString("- **Client Address**: `" + string(t.Client) + "`\n")
	sb.WriteString("- **Auditor Address**: `" + string(t.Auditor) + "`\n")
	sb.WriteString("- **AI Agent Address**: `" + string(t.Agent) + "`\n\n")

	sb.WriteString("### 🔐 Cryptographic Verification\n")
	sb.WriteString("- **Expected Hash**: `" + t.ExpectedHash + "`\n")
	sb.WriteString("- **Submitted Proof Hash**: `" + t.SubmittedHash + "`\n")
	sb.WriteString("- **Model Metadata**: `" + t.ModelMetadata + "`\n")
	sb.WriteString("- **Auditor Notes**: " + t.AuditorNotes + "\n\n")

	sb.WriteString("[← Back to Ledger Dashboard]("")\n")
	return sb.String()
}

func countByStatus(status TaskStatus) int {
	c := 0
	for _, t := range tasks {
		if t.Status == status {
			c++
		}
	}
	return c
}

func formatGnot(ugnot int64) string {
	whole := ugnot / 1000000
	remainder := ugnot % 1000000
	return strconv.FormatInt(whole, 10) + "." + strconv.FormatInt(remainder, 10)
}
