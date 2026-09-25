// Founding Memba DAO candidate. Initial roles follow the approved policy.
// Keep the host private. This realm supports governed role changes, same-person key recovery and the fixed application adapters named in Render.
package memba_dao

import (
    "chain"
    "gno.land/p/samcrew/memba_weighted_host"
    "gno.land/p/samcrew/memba_weighted_policy"
)

var host *memba_weighted_host.Host
var feedbackPolicy = memba_weighted_host.NewFeedbackPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var channelsPolicy = memba_weighted_host.NewChannelsPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var feedPolicy = memba_weighted_host.NewFeedPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var badgesPolicy = memba_weighted_host.NewBadgesPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var escrowPolicy = memba_weighted_host.NewEscrowPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var appstorePolicy = memba_weighted_host.NewAppstorePolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf", "g1jw76lxvzjafw2kyjhdnzwggcftyhnlfjaer2u0")
var arcadePolicy = memba_weighted_host.NewArcadePolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var questPolicy = memba_weighted_host.NewQuestPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var reviewsPolicy = memba_weighted_host.NewReviewsPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "gno.land/r/samcrew/memba_reviews_v2", "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")
var marketPolicy = memba_weighted_host.NewMarketPolicy(chain.PackageAddress("gno.land/r/samcrew/memba_dao"), "g1jw76lxvzjafw2kyjhdnzwggcftyhnlfjaer2u0", "g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf")

func init(cur realm) {
    host = memba_weighted_host.NewWithApplications([]memba_weighted_host.Seat{
        {Member: memba_weighted_policy.Member{PersonID: "zxxma", Address: "g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c", Founder: true}, Admin: true, Finance: true},
        {Member: memba_weighted_policy.Member{PersonID: "mikael", Address: "g1lyejwwmxef5tn8nx69saykmgm8rlr4xq9yeh3z", Founder: false}, Admin: false, Finance: false},
        {Member: memba_weighted_policy.Member{PersonID: "ghost", Address: "g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv", Founder: false}, Admin: false, Finance: false},
        {Member: memba_weighted_policy.Member{PersonID: "mikecito", Address: "g1cvr48r7l7lkmvp77cr6zg2zhu26jgfwr0y8pew", Founder: false}, Admin: false, Finance: false},
        {Member: memba_weighted_policy.Member{PersonID: "david", Address: "g1rayfgklwl0aspz488wvrcrvt7t2quy6q06lgk2", Founder: false}, Admin: false, Finance: false},
        {Member: memba_weighted_policy.Member{PersonID: "lours", Address: "g1nvxz94ukmggfx4mlldwae3cpde99qmldtcgm9u", Founder: false}, Admin: false, Finance: false},
        {Member: memba_weighted_policy.Member{PersonID: "dadidou", Address: "g1jjeuv48j3pmsmnvga8jwfnc2amfyv9c30zx04y", Founder: false}, Admin: false, Finance: false},
    }, memba_weighted_host.ApplicationPolicies{Market:marketPolicy, Reviews:reviewsPolicy, Quest:questPolicy, Arcade:arcadePolicy, Appstore:appstorePolicy, Escrow:escrowPolicy, Badges:badgesPolicy, Feed:feedPolicy, Channels:channelsPolicy, Feedback:feedbackPolicy}, cur)
}

func ProposeRole(cur realm, target address, role string, grant bool) uint64 {
    return host.ProposeRole(target, memba_weighted_host.Role(role), grant, cur)
}
func ProposeRecovery(cur realm, personID string, oldAddress, newAddress address) uint64 {
    return host.ProposeRecovery(personID, oldAddress, newAddress, cur)
}
func Vote(cur realm, id uint64, vote string) { host.Vote(id, memba_weighted_policy.Vote(vote), cur) }
func Execute(cur realm, id uint64) { if host.Proposal(id).Feedback { executeFeedback(cur, id); return }; if host.Proposal(id).Channels { executeChannels(cur, id); return }; if host.Proposal(id).Feed { executeFeed(cur, id); return }; if host.Proposal(id).Badges { executeBadges(cur, id); return }; if host.Proposal(id).Escrow { executeEscrow(cur, id); return }; if host.Proposal(id).Appstore { executeAppstore(cur, id); return }; if host.Proposal(id).Arcade { executeArcade(cur, id); return }; if host.Proposal(id).Quest { executeQuest(cur, id); return };
    if host.Proposal(id).Reviews { executeReviews(cur, id); return }
    if host.Proposal(id).Market { executeMarket(cur, id) } else { host.Execute(id, cur) }
}
func GetConfigJSON() string { return host.ConfigJSON() }
func GetMembersJSON() string { return host.MembersJSON() }
func GetProposalJSON(id uint64) string { return host.ProposalJSON(id) }
func GetProposalsJSON(before uint64, limit int) string { return host.ProposalsJSON(before, limit) }
func GetBallotJSON(proposalID string, voter address) string { return host.BallotJSON(proposalID, voter) }
func GetPendingVotesJSON(voter address, before string, limit int) string { return host.PendingVotesJSON(voter, before, limit) }

func Render(path string) string {
    return "# Memba DAO\n\n## Members (7)\n\nOne founder with 2 voting points and six equal core developers with 1 point each.\n\nRole changes and member-key recovery require 6 points and at least 4 people after 24 hours, or 5 core developers after 72 hours. Voting closes after 7 days; qualified proposals retain their execution delay.\n\nFixed governance of market config, reviews, quests, arcade, App Store, escrow, badges, feed, channels and feedback is available. A return proposal only stages the configured successor; separate acceptance is required. DAO state migration and treasury spending are not enabled."
}
