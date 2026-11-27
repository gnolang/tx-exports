package bountysiege

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

var (
	nextCommentID   uint64
	commentsByKey   = map[string][]Comment{}
	commentAddrCnt  = map[string]int{}
)

func commentKey(mt bs_core.MissionType, id uint64) string {
	return mt.String() + ":" + strconv.FormatUint(id, 10)
}

// PostComment adds a public Q&A comment to a Quest, Contest, or Raid.
// Append-only; enforces 500-byte cap, max 100 comments/mission, max 10/addr/mission.
func PostComment(cur realm, missionType uint8, missionID uint64, body string) uint64 {
	requireNonPayableEOA(0, cur)
	requireRolesInitialized()

	mt := bs_core.MissionType(missionType)
	if err := bs_core.ValidateText(body, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("invalid comment body: " + err.Error())
	}

	author := cur.Previous().Address()
	roleTag := resolveCommentRoleTag(mt, missionID, author)

	key := commentKey(mt, missionID)
	list := commentsByKey[key]
	if len(list) >= bs_core.MaxCommentsPerMission {
		panic("comment limit (100) reached for this mission")
	}
	addrKey := key + "|" + author.String()
	if commentAddrCnt[addrKey] >= bs_core.MaxCommentsPerAddr {
		panic("per-address comment limit (10) reached for this mission")
	}

	nextCommentID++
	c := Comment{
		ID:        nextCommentID,
		Author:    author,
		RoleTag:   roleTag,
		Body:      strings.TrimSpace(body),
		CreatedAt: time.Now().Unix(),
	}
	commentsByKey[key] = append(list, c)
	commentAddrCnt[addrKey]++
	return c.ID
}

func resolveCommentRoleTag(mt bs_core.MissionType, id uint64, author address) string {
	switch mt {
	case bs_core.MissionQuest:
		q := mustGetQuest(id)
		if author == q.Sponsor {
			return "SPONSOR"
		}
		if att := q.activeAttempt(); att != nil && att.Builder == author {
			return "BUILDER"
		}
		return "COMMUNITY"
	case bs_core.MissionContest:
		c := mustGetContest(id)
		if author == c.Sponsor {
			return "SPONSOR"
		}
		if _, ok := c.entryIdxByAddr[author]; ok {
			return "SUBMITTER"
		}
		return "COMMUNITY"
	case bs_core.MissionRaid:
		r := mustGetRaid(id)
		if author == r.Sponsor {
			return "SPONSOR"
		}
		for _, sl := range r.Slots {
			if att := sl.activeAttempt(); att != nil && att.Builder == author {
				return "BUILDER"
			}
		}
		return "COMMUNITY"
	default:
		panic("unsupported mission type for comment")
	}
}

func getComments(mt bs_core.MissionType, id uint64) []Comment {
	return commentsByKey[commentKey(mt, id)]
}
