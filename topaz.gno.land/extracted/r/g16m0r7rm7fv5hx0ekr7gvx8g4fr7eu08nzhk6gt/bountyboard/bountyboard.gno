package bountyboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type TaskStatus int

const (
	StatusOpen TaskStatus = iota
	StatusClaimed
	StatusApproved
	StatusExpiredPaid
	StatusCancelled
	StatusRefundedNoSubmission
)

func (s TaskStatus) String() string {
	switch s {
	case StatusOpen:
		return "Open"
	case StatusClaimed:
		return "Claimed"
	case StatusApproved:
		return "Approved"
	case StatusExpiredPaid:
		return "ExpiredPaid"
	case StatusCancelled:
		return "Cancelled"
	case StatusRefundedNoSubmission:
		return "RefundedNoSubmission"
	default:
		return "Unknown"
	}
}

type Submission struct {
	Claimer address
	Content string
	AtBlock int64
	Seq     int64
}

type Task struct {
	ID             int64
	Owner          address
	Title          string
	Description    string
	Reward         int64
	DeadlineHeight int64
	Status         TaskStatus
	Claimers       *avl.Tree
	Submissions    *avl.Tree
	SubmitCount    int64
	Winner         address
	CreatedAtBlock int64
}

var (
	tasks       = avl.NewTree()
	nextTaskID  int64
	totalLocked int64
)

func CreateTask(cur realm, title, description string, blocksUntilDeadline int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: only direct user calls (maketx call) can create tasks")
	}
	if blocksUntilDeadline <= 0 {
		panic("bountyboard: blocksUntilDeadline must be positive")
	}
	if title == "" {
		panic("bountyboard: title cannot be empty")
	}

	sent := unsafe.OriginSend()
	reward := sent.AmountOf("ugnot")
	if reward <= 0 {
		panic("bountyboard: task must be created with a positive ugnot reward")
	}

	caller := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()

	nextTaskID++
	id := nextTaskID

	task := &Task{
		ID:             id,
		Owner:          caller,
		Title:          title,
		Description:    description,
		Reward:         reward,
		DeadlineHeight: nowHeight + blocksUntilDeadline,
		Status:         StatusOpen,
		Claimers:       avl.NewTree(),
		Submissions:    avl.NewTree(),
		CreatedAtBlock: nowHeight,
	}

	tasks.Set(itoa(id), task)
	totalLocked += reward

	return id
}

func ClaimTask(cur realm, taskID int64) {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: only direct user calls can claim tasks")
	}

	task := mustGetTask(taskID)
	caller := cur.Previous().Address()

	if task.Status != StatusOpen && task.Status != StatusClaimed {
		panic("bountyboard: task is not open for claims (status=" + task.Status.String() + ")")
	}
	if runtime.ChainHeight() >= task.DeadlineHeight {
		panic("bountyboard: task deadline has passed")
	}
	if caller == task.Owner {
		panic("bountyboard: task owner cannot claim their own task")
	}
	if task.Claimers.Get(caller.String()) != nil {
		panic("bountyboard: address already claimed this task")
	}

	task.Claimers.Set(caller.String(), true)
	task.Status = StatusClaimed
}

func SubmitWork(cur realm, taskID int64, content string) {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: only direct user calls can submit work")
	}
	if content == "" {
		panic("bountyboard: submission content cannot be empty")
	}

	task := mustGetTask(taskID)
	caller := cur.Previous().Address()

	if task.Status != StatusClaimed {
		panic("bountyboard: task is not in claimed state (status=" + task.Status.String() + ")")
	}
	if runtime.ChainHeight() >= task.DeadlineHeight {
		panic("bountyboard: task deadline has passed")
	}
	if task.Claimers.Get(caller.String()) == nil {
		panic("bountyboard: caller has not claimed this task")
	}
	if task.Submissions.Get(caller.String()) != nil {
		panic("bountyboard: caller has already submitted work for this task")
	}

	task.SubmitCount++
	task.Submissions.Set(caller.String(), &Submission{
		Claimer: caller,
		Content: content,
		AtBlock: runtime.ChainHeight(),
		Seq:     task.SubmitCount,
	})
}

func ApproveSubmission(cur realm, taskID int64, winner address) {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: only direct user calls can approve submissions")
	}

	task := mustGetTask(taskID)
	caller := cur.Previous().Address()

	if caller != task.Owner {
		panic("bountyboard: only the task owner can approve a submission")
	}
	if task.Status != StatusClaimed {
		panic("bountyboard: task has no pending submissions to approve (status=" + task.Status.String() + ")")
	}
	if task.Submissions.Get(winner.String()) == nil {
		panic("bountyboard: chosen winner has not submitted work for this task")
	}

	task.Status = StatusApproved
	task.Winner = winner
	reward := task.Reward
	totalLocked -= reward

	payout(cur, winner, reward)
}

func CancelTask(cur realm, taskID int64) {
	if !cur.Previous().IsUserCall() {
		panic("bountyboard: only direct user calls can cancel tasks")
	}

	task := mustGetTask(taskID)
	caller := cur.Previous().Address()

	if caller != task.Owner {
		panic("bountyboard: only the task owner can cancel")
	}
	if task.Status != StatusOpen && task.Status != StatusClaimed {
		panic("bountyboard: task cannot be cancelled in status=" + task.Status.String())
	}
	if task.Submissions.Size() > 0 {
		panic("bountyboard: cannot cancel a task that already has submissions")
	}

	task.Status = StatusCancelled
	reward := task.Reward
	totalLocked -= reward

	payout(cur, task.Owner, reward)
}

func SettleExpired(cur realm, taskID int64) {
	task := mustGetTask(taskID)

	if task.Status != StatusOpen && task.Status != StatusClaimed {
		panic("bountyboard: task is not in a settleable state (status=" + task.Status.String() + ")")
	}
	if runtime.ChainHeight() < task.DeadlineHeight {
		panic("bountyboard: task deadline has not passed yet")
	}

	reward := task.Reward

	if task.Submissions.Size() == 0 {
		task.Status = StatusRefundedNoSubmission
		totalLocked -= reward
		payout(cur, task.Owner, reward)
		return
	}

	winner := firstSubmitter(task)

	task.Status = StatusExpiredPaid
	task.Winner = winner
	totalLocked -= reward
	payout(cur, winner, reward)
}

func mustGetTask(taskID int64) *Task {
	raw := tasks.Get(itoa(taskID))
	if raw == nil {
		panic("bountyboard: task not found")
	}
	task, ok := raw.(*Task)
	if !ok {
		panic("bountyboard: internal error, corrupted task entry")
	}
	return task
}

func firstSubmitter(task *Task) address {
	var winner address
	var minSeq int64 = -1

	task.Submissions.Iterate("", "", func(key string, value interface{}) bool {
		sub, ok := value.(*Submission)
		if !ok {
			return false
		}
		if minSeq == -1 || sub.Seq < minSeq {
			minSeq = sub.Seq
			winner = sub.Claimer
		}
		return false
	})

	if minSeq == -1 {
		panic("bountyboard: internal error, no submissions found despite Size()>0")
	}
	return winner
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("bountyboard: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetTaskStatus(taskID int64) string {
	return mustGetTask(taskID).Status.String()
}

func GetTaskReward(taskID int64) int64 {
	return mustGetTask(taskID).Reward
}

func GetTaskOwner(taskID int64) address {
	return mustGetTask(taskID).Owner
}

func GetTaskDeadlineHeight(taskID int64) int64 {
	return mustGetTask(taskID).DeadlineHeight
}

func GetTaskWinner(taskID int64) address {
	return mustGetTask(taskID).Winner
}

func GetSubmissionCount(taskID int64) int64 {
	return int64(mustGetTask(taskID).Submissions.Size())
}

func TotalLocked() int64 {
	return totalLocked
}
