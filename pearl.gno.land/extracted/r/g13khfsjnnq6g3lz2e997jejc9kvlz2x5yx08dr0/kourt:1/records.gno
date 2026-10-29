package kourt
type answerRecord struct {
	score          int
	activePriority uint64
}
func creditUpheld(c *Court, who address) {
	r := getRecord(c, who)
	wasQualified := r.score >= priorityNetRecord
	r.score++
	if !wasQualified && r.score >= priorityNetRecord {
		c.qualifiedCount++
	}
}
func resetOverturned(c *Court, who address) {
	r := getRecord(c, who)
	if r.score >= priorityNetRecord {
		c.qualifiedCount--
	}
	r.score = 0
}
func priorityGateActive(c *Court) bool { return c.qualifiedCount >= priorityColdStartN }
func mayAnswerInPriority(c *Court, who address) bool {
	r := getRecord(c, who)
	return r.score >= priorityNetRecord && r.activePriority == 0
}
func holdPriority(c *Court, who address, claimID uint64) {
	getRecord(c, who).activePriority = claimID
}
func releasePriority(c *Court, who address, claimID uint64) {
	r := getRecord(c, who)
	if r.activePriority == claimID {
		r.activePriority = 0
	}
}
func getRecord(c *Court, who address) *answerRecord {
	if v := c.records.Get(string(who)); v != nil {
		return v.(*answerRecord)
	}
	r := &answerRecord{}
	c.records.Set(string(who), r)
	return r
}
func AnswerRecord(courtSlug string, who address) int {
	c := mustCourt(courtSlug)
	if v := c.records.Get(string(who)); v != nil {
		return v.(*answerRecord).score
	}
	return 0
}
func PriorityGateActive(courtSlug string) bool {
	return priorityGateActive(mustCourt(courtSlug))
}
