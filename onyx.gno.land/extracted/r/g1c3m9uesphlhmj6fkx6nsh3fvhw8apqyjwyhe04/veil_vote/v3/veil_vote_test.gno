package veil_vote

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/groth16/v2"
	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/semaphore/v2"
)

const (
	group1Root         = "15a424cd40c03bc1e069f90ea4c8d5d0769e6f45a90a37d94abb5fdfbe15ffec"
	group1ExpandedRoot = "0773d9659abeaf50b7b2b05461168c5dd7b476e3f0c51a9f6db6c4a4c8fb8acd"
	group2Root         = "24c7c546821c07bd81695b5d290c8d69f617d25d5df9856b81bfbc69166bcb09"
	id0Comm            = "135d250fea6e2057923268e507ea86d7337da14f5ce313302cb0db3c445c2859"
	id1Comm            = "07cbd8da449651472a459983c73128122dc002fba61dbb400bd3ef8daf168579"
	id2Comm            = "23d2cb21e081f7c75930da74846ea866aff29233a7fe38caefdbe0719f0c941a"
	id3Comm            = "008c8fee9f3541a6b36914a2ed827b2f93a459a48eefc2f0b605003254d4011f"
	nonMemComm         = "2145ac5e074e03763115424fcc75a4b0938ef056f0cc5e70aad3d6ac4ab1f6e4"
)

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Fatalf("%s: expected panic, but succeeded", label)
	}
}

func TestAdversarialVotingSuite(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	CreateGroup(cross(cur), 1, 10, admin)
	AddMember(cross(cur), 1, id0Comm)
	AddMember(cross(cur), 1, id1Comm)
	AddMember(cross(cur), 1, id2Comm)
	PublishRoot(cross(cur), 1, group1Root)

	CreateGroup(cross(cur), 2, 10, admin)
	AddMember(cross(cur), 2, id1Comm)
	AddMember(cross(cur), 2, id2Comm)
	PublishRoot(cross(cur), 2, group2Root)

	// Poll 42 and 43 freeze group1Root at creation time.
	CreatePoll(cross(cur), 42, 1, "Proposal 42", "Abstain,Yes,No", 0, 0)
	CreatePoll(cross(cur), 43, 1, "Proposal 43", "Abstain,Yes,No", 0, 0)

	if GetPollSnapshotRoot(42) != group1Root {
		t.Fatalf("expected frozen snapshot root %s, got %s", group1Root, GetPollSnapshotRoot(42))
	}
	if GetGroupCommitments(1) == "" {
		t.Fatalf("expected non-empty GetGroupCommitments")
	}

	// Duplicate commitment must be rejected.
	assertPanics(t, "duplicate commitment", func() { AddMember(cross(cur), 1, id0Comm) })

	// Post-poll membership update + root publish must NOT alter Poll 42's frozen snapshot!
	AddMember(cross(cur), 1, id3Comm)
	PublishRoot(cross(cur), 1, group1ExpandedRoot)
	if GetPollSnapshotRoot(42) != group1Root {
		t.Fatalf("poll 42 snapshot root mutated after PublishRoot")
	}

	voter := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	attacker := address("g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj")

	// Unauthorized administrative & membership mutations rejected.
	testing.SetRealm(testing.NewUserRealm(attacker))
	assertPanics(t, "unauth CreateGroup", func() { CreateGroup(cross(cur), 99, 10, attacker) })
	assertPanics(t, "unauth AddMember", func() { AddMember(cross(cur), 1, nonMemComm) })
	assertPanics(t, "unauth PublishRoot", func() { PublishRoot(cross(cur), 1, group2Root) })
	assertPanics(t, "unauth CreatePoll", func() { CreatePoll(cross(cur), 99, 1, "Bad", "A,B", 0, 0) })
	assertPanics(t, "unauth ClosePoll", func() { ClosePoll(cross(cur), 42) })

	testing.SetRealm(testing.NewUserRealm(voter))

	// Newly registered member using post-poll expanded root is rejected in Poll 42!
	assertPanics(t, "new member post-poll root rejected", func() {
		Vote(cross(cur), 42, 10, group1ExpandedRoot, "1a90429b75db7c7f31013db0431cd44775ef79aec1cc455e42aa46cff14ef868", 1, "1b87ffcd2254f0adefbbc070a4b7193c159222d52485a5cc12efda20275307cb28a88557912b8cb0cc79deecddf5067e65378dbb12b37408398f9b66b9fb5765", "22b55e14e77cc5bcca4041a9b15a02a81733bc6e7f544f0ae96fe76e1b79a6a116238e324f5ca0a21ef74bd75c712ec5b39e1b837477c0bee4a22f1e90b1b7d50939acd24e45d9d89d95b4eb0be2f7e1a20c92a664d9b7904d8fe084447bbfa70e5b5d4e02e7e589192c215ed9c545449bdeb341fc69b1a3e90d76e9c0b481b1", "22161ca25169a26b6ca169b433d00e96a5664359454455cd5b3be324bd4d8f292dab9013f170accac899e3e94af2032cc9898b88ae7183324096c1b6d8771c89")
	})

	// Modified vote choice rejected AND failed verification does NOT consume nullifier.
	assertPanics(t, "modified vote choice", func() {
		Vote(cross(cur), 42, 10, group1Root, "16889590e06ea0d0fa9537dbe30d9c4025afa08b65542d9da4e0ac583aa1d909", 2, "088da851c74b6054a594de3fb7729da1dcc5194d9209bb24fb22428a642e66ef00ba2bb74e4279c888b83bb260bcc5f7d592679dae9dad9f2a7a87a6867eb68e", "1fbd9acb35e3bcd2a04e5d46556286f774ace7f0d5f073329c61c742a3e292341c8d97a6b03b0ff2bcc37ac249af2f35c840a623c3f080a6a1dba9a71e3b3a0b13af9b09194d36b780da6f746a3682a7d9cb86fe4f540a83aeaf5600cc40cf94199dbd4300ee8b64943c3ec5bd653cda63c4d18f28884ac9db4226cb121864e3", "1c37892a407a96c8c7c80f16aa37e6f3bb7e7dabcc44cc2425ad5b03da3f108715436cbf1403d555baf073884d1e685e5c4b6ad947651b524450e1760e1c1456")
	})
	if GetPollTally(42, 2) != 0 {
		t.Fatalf("tally updated on failed vote")
	}

	// Previously eligible member id0 using frozen root succeeds!
	res := Vote(cross(cur), 42, 10, group1Root, "16889590e06ea0d0fa9537dbe30d9c4025afa08b65542d9da4e0ac583aa1d909", 1, "088da851c74b6054a594de3fb7729da1dcc5194d9209bb24fb22428a642e66ef00ba2bb74e4279c888b83bb260bcc5f7d592679dae9dad9f2a7a87a6867eb68e", "1fbd9acb35e3bcd2a04e5d46556286f774ace7f0d5f073329c61c742a3e292341c8d97a6b03b0ff2bcc37ac249af2f35c840a623c3f080a6a1dba9a71e3b3a0b13af9b09194d36b780da6f746a3682a7d9cb86fe4f540a83aeaf5600cc40cf94199dbd4300ee8b64943c3ec5bd653cda63c4d18f28884ac9db4226cb121864e3", "1c37892a407a96c8c7c80f16aa37e6f3bb7e7dabcc44cc2425ad5b03da3f108715436cbf1403d555baf073884d1e685e5c4b6ad947651b524450e1760e1c1456")
	if res != "RECORDED" || GetPollTally(42, 1) != 1 {
		t.Fatalf("valid vote failed: res=%s tally=%d", res, GetPollTally(42, 1))
	}

	// Double vote in same poll rejected.
	assertPanics(t, "double vote in same poll", func() {
		Vote(cross(cur), 42, 10, group1Root, "16889590e06ea0d0fa9537dbe30d9c4025afa08b65542d9da4e0ac583aa1d909", 1, "088da851c74b6054a594de3fb7729da1dcc5194d9209bb24fb22428a642e66ef00ba2bb74e4279c888b83bb260bcc5f7d592679dae9dad9f2a7a87a6867eb68e", "1fbd9acb35e3bcd2a04e5d46556286f774ace7f0d5f073329c61c742a3e292341c8d97a6b03b0ff2bcc37ac249af2f35c840a623c3f080a6a1dba9a71e3b3a0b13af9b09194d36b780da6f746a3682a7d9cb86fe4f540a83aeaf5600cc40cf94199dbd4300ee8b64943c3ec5bd653cda63c4d18f28884ac9db4226cb121864e3", "1c37892a407a96c8c7c80f16aa37e6f3bb7e7dabcc44cc2425ad5b03da3f108715436cbf1403d555baf073884d1e685e5c4b6ad947651b524450e1760e1c1456")
	})

	// Same identity CAN vote in distinct poll (poll 43).
	res2 := Vote(cross(cur), 43, 10, group1Root, "252addf0a457c1bf599965840794ee2b90d8fbfc56b54c0b3d3c19ac503cff22", 2, "247ba00d8eb483970fc32c82af7dd3f8abec35d480c4bb2fbc96dcf3a2605b711242950cc91c6e5095822e668d582d14864327a926d8aca6164b34cfe768099f", "1463ef7790757f32fda199eb68dc19b774ad8197a0bfc8077d959ebd4cf847b22a8eb1f85673af70c2bbbdece685a7c8c05b53726f6e948ae38cdc3b8cd2f2b918d6f88464aa4f724b69907daa5045117e210f5fb6622426e5e83400afaf04660c8561a256b87d5826509ada485f992bcbeebcc770dbbd4e3e35e59e25f6985d", "129c7d50e041834afc8d7a9f4ea454a77bf92732bb198971ef8f677ba1d8b4ba1df5b63f8f3bc72cf9f80cc551ceee36659564ba4861c01c7744a6c059302230")
	if res2 != "RECORDED" || GetPollTally(43, 2) != 1 {
		t.Fatalf("distinct poll vote failed")
	}

	// Proof for another poll (poll 43) rejected in poll 42.
	assertPanics(t, "proof for another poll", func() {
		Vote(cross(cur), 42, 10, group1Root, "252addf0a457c1bf599965840794ee2b90d8fbfc56b54c0b3d3c19ac503cff22", 2, "247ba00d8eb483970fc32c82af7dd3f8abec35d480c4bb2fbc96dcf3a2605b711242950cc91c6e5095822e668d582d14864327a926d8aca6164b34cfe768099f", "1463ef7790757f32fda199eb68dc19b774ad8197a0bfc8077d959ebd4cf847b22a8eb1f85673af70c2bbbdece685a7c8c05b53726f6e948ae38cdc3b8cd2f2b918d6f88464aa4f724b69907daa5045117e210f5fb6622426e5e83400afaf04660c8561a256b87d5826509ada485f992bcbeebcc770dbbd4e3e35e59e25f6985d", "129c7d50e041834afc8d7a9f4ea454a77bf92732bb198971ef8f677ba1d8b4ba1df5b63f8f3bc72cf9f80cc551ceee36659564ba4861c01c7744a6c059302230")
	})

	// Proof for another group (group 2) rejected in group 1 poll 42.
	assertPanics(t, "proof for another group", func() {
		Vote(cross(cur), 42, 10, group2Root, "00b7a3fdc7ad42bf6225929477722eb0f8d86a5eb261e89e780141221ad905f2", 1, "10f044be48f9dd29c0d3087984cb98235a8cd9b22efbd5fe6201f6d2901c4033229ef57a545f9deb0adc123dc733e0dd3273523f1656a79379846c975e039b4b", "19ab4f9ccd386a8f7df27ee57b90bf11e952b24704d0cd402d8dd72880f9a33703b5c1fbe8f99dba12d1a284edaaedcc14f04d59ee055d397841e91d5bb228af1f38400687ee7186c3347dd4e06aea7fabac894b0ef1b7f4627679a463c565e30405d05441b1d9a340ca0a087987355f55c1b0559c12168ea84d61c8b298f13f", "237b00da3556358e44c36418f12970dcff97446b6d27e2e77390cc9b97e788d62697e97ec965cce2444d5c6be995ac9df9d65e8094de375c97c5d99caca5d7bf")
	})

	// Arbitrary root rejected.
	assertPanics(t, "arbitrary root", func() {
		Vote(cross(cur), 42, 10, nonMemComm, "092ca1fe64528b2dc191036636148e1a21d8178159b770e3548c6c8a7e45af21", 2, "28423ca32024cc00cb8f75bf1ad81d64827ff6583d0485f7d5efddba613fda1c252d3910c29a70539311f61d1ba6c4254a98a5003b4b0d780f96760b5f760e33", "1e0ec649e4a3c9f29dbc1678602dea9e21a4600e57c3a9dce89e78239c5ec7101d7ae6b0dee145bbacb6fe42f0e8429e3b3fe0f6f01b00e6738a4ec68cbc4dd92ca024757a576ad148d4c9389b20302470414db3ff220eb63f7d3a5375c547cc2a0f4daf9f7fb75ec1cb0f94dfe7e473711fd3e5499cc14d90019d536e46cbd5", "2b2eb87e86900200cc5499174d38aa72fd81bbcf8dc75712bf8f19f7008c892d24b8fb1b22f256489f53c938d082ed450190fc2f8f97b2101b7534c6820eaa12")
	})

	// Unsupported depth rejected.
	assertPanics(t, "unsupported depth", func() {
		Vote(cross(cur), 42, 20, group1Root, "092ca1fe64528b2dc191036636148e1a21d8178159b770e3548c6c8a7e45af21", 2, "28423ca32024cc00cb8f75bf1ad81d64827ff6583d0485f7d5efddba613fda1c252d3910c29a70539311f61d1ba6c4254a98a5003b4b0d780f96760b5f760e33", "1e0ec649e4a3c9f29dbc1678602dea9e21a4600e57c3a9dce89e78239c5ec7101d7ae6b0dee145bbacb6fe42f0e8429e3b3fe0f6f01b00e6738a4ec68cbc4dd92ca024757a576ad148d4c9389b20302470414db3ff220eb63f7d3a5375c547cc2a0f4daf9f7fb75ec1cb0f94dfe7e473711fd3e5499cc14d90019d536e46cbd5", "2b2eb87e86900200cc5499174d38aa72fd81bbcf8dc75712bf8f19f7008c892d24b8fb1b22f256489f53c938d082ed450190fc2f8f97b2101b7534c6820eaa12")
	})

	// Invalid vote option rejected.
	assertPanics(t, "invalid vote option", func() {
		Vote(cross(cur), 42, 10, group1Root, "092ca1fe64528b2dc191036636148e1a21d8178159b770e3548c6c8a7e45af21", 99, "28423ca32024cc00cb8f75bf1ad81d64827ff6583d0485f7d5efddba613fda1c252d3910c29a70539311f61d1ba6c4254a98a5003b4b0d780f96760b5f760e33", "1e0ec649e4a3c9f29dbc1678602dea9e21a4600e57c3a9dce89e78239c5ec7101d7ae6b0dee145bbacb6fe42f0e8429e3b3fe0f6f01b00e6738a4ec68cbc4dd92ca024757a576ad148d4c9389b20302470414db3ff220eb63f7d3a5375c547cc2a0f4daf9f7fb75ec1cb0f94dfe7e473711fd3e5499cc14d90019d536e46cbd5", "2b2eb87e86900200cc5499174d38aa72fd81bbcf8dc75712bf8f19f7008c892d24b8fb1b22f256489f53c938d082ed450190fc2f8f97b2101b7534c6820eaa12")
	})

	// Multiple distinct members can vote successfully.
	res3 := Vote(cross(cur), 42, 10, group1Root, "092ca1fe64528b2dc191036636148e1a21d8178159b770e3548c6c8a7e45af21", 2, "28423ca32024cc00cb8f75bf1ad81d64827ff6583d0485f7d5efddba613fda1c252d3910c29a70539311f61d1ba6c4254a98a5003b4b0d780f96760b5f760e33", "1e0ec649e4a3c9f29dbc1678602dea9e21a4600e57c3a9dce89e78239c5ec7101d7ae6b0dee145bbacb6fe42f0e8429e3b3fe0f6f01b00e6738a4ec68cbc4dd92ca024757a576ad148d4c9389b20302470414db3ff220eb63f7d3a5375c547cc2a0f4daf9f7fb75ec1cb0f94dfe7e473711fd3e5499cc14d90019d536e46cbd5", "2b2eb87e86900200cc5499174d38aa72fd81bbcf8dc75712bf8f19f7008c892d24b8fb1b22f256489f53c938d082ed450190fc2f8f97b2101b7534c6820eaa12")
	if res3 != "RECORDED" || GetPollTally(42, 2) != 1 {
		t.Fatalf("second member vote failed")
	}

	// Closed poll rejects submissions.
	testing.SetRealm(testing.NewUserRealm(admin))
	ClosePoll(cross(cur), 43)
	testing.SetRealm(testing.NewUserRealm(voter))
	assertPanics(t, "closed poll", func() {
		Vote(cross(cur), 43, 10, group1Root, "092ca1fe64528b2dc191036636148e1a21d8178159b770e3548c6c8a7e45af21", 2, "28423ca32024cc00cb8f75bf1ad81d64827ff6583d0485f7d5efddba613fda1c252d3910c29a70539311f61d1ba6c4254a98a5003b4b0d780f96760b5f760e33", "1e0ec649e4a3c9f29dbc1678602dea9e21a4600e57c3a9dce89e78239c5ec7101d7ae6b0dee145bbacb6fe42f0e8429e3b3fe0f6f01b00e6738a4ec68cbc4dd92ca024757a576ad148d4c9389b20302470414db3ff220eb63f7d3a5375c547cc2a0f4daf9f7fb75ec1cb0f94dfe7e473711fd3e5499cc14d90019d536e46cbd5", "2b2eb87e86900200cc5499174d38aa72fd81bbcf8dc75712bf8f19f7008c892d24b8fb1b22f256489f53c938d082ed450190fc2f8f97b2101b7534c6820eaa12")
	})

	// Invalid rootPublisher rejected; TransferAdmin rotates control and rejects invalid addresses.
	testing.SetRealm(testing.NewUserRealm(admin))
	assertPanics(t, "invalid rootPublisher", func() {
		CreateGroup(cross(cur), 99, 10, address(""))
	})
	assertPanics(t, "invalid newAdmin", func() {
		TransferAdmin(cross(cur), address(""))
	})
	newAdmin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	TransferAdmin(cross(cur), newAdmin)
	assertPanics(t, "old admin rejected after TransferAdmin", func() {
		CreateGroup(cross(cur), 99, 10, admin)
	})
	testing.SetRealm(testing.NewUserRealm(newAdmin))
	TransferAdmin(cross(cur), admin)

	// Cross-app and cross-network replay rejected at Primitives layer.
	rBytes, _ := decodeHex32(group1Root)
	nBytes, _ := decodeHex32("16889590e06ea0d0fa9537dbe30d9c4025afa08b65542d9da4e0ac583aa1d909")
	pf, _ := groth16.ParseProofHex("088da851c74b6054a594de3fb7729da1dcc5194d9209bb24fb22428a642e66ef00ba2bb74e4279c888b83bb260bcc5f7d592679dae9dad9f2a7a87a6867eb68e", "1fbd9acb35e3bcd2a04e5d46556286f774ace7f0d5f073329c61c742a3e292341c8d97a6b03b0ff2bcc37ac249af2f35c840a623c3f080a6a1dba9a71e3b3a0b13af9b09194d36b780da6f746a3682a7d9cb86fe4f540a83aeaf5600cc40cf94199dbd4300ee8b64943c3ec5bd653cda63c4d18f28884ac9db4226cb121864e3", "1c37892a407a96c8c7c80f16aa37e6f3bb7e7dabcc44cc2425ad5b03da3f108715436cbf1403d555baf073884d1e685e5c4b6ad947651b524450e1760e1c1456")
	if err := semaphore.VerifyAndConsume(vks, groups, semaphore.NewNullifierSet(), 1, 10, rBytes, nBytes, semaphore.Uint64ToBE32(1), semaphore.DomainScopeFull("onyx-1", "gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/veil_vote/v3", 1, 42), pf); err == nil {
		t.Fatalf("expected error for cross-network replay")
	}
}

func TestResourceLimitsAndPagination(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))

	// Unsupported depth rejected at realm boundary.
	assertPanics(t, "unsupported depth 20", func() {
		CreateGroup(cross(cur), 500, 20, admin)
	})

	// Empty and oversized titles rejected.
	assertPanics(t, "empty title", func() {
		CreatePoll(cross(cur), 500, 1, "   ", "Yes,No", 0, 0)
	})
	assertPanics(t, "oversized title", func() {
		CreatePoll(cross(cur), 500, 1, strings.Repeat("t", MaxTitleLen+1), "Yes,No", 0, 0)
	})

	// Max title & 32 options accepted; 33 options & oversized option rejected.
	var opts32 []string
	for i := 0; i < MaxOptions; i++ {
		opts32 = append(opts32, "opt"+strconv.Itoa(i))
	}
	CreatePoll(cross(cur), 501, 1, strings.Repeat("t", MaxTitleLen), strings.Join(opts32, ","), 0, 0)
	assertPanics(t, "33 options", func() {
		CreatePoll(cross(cur), 502, 1, "Too many", strings.Join(append(opts32, "extra"), ","), 0, 0)
	})
	assertPanics(t, "oversized option", func() {
		CreatePoll(cross(cur), 503, 1, "Long opt", strings.Repeat("o", MaxOptionLen+1)+",No", 0, 0)
	})

	// Large membership group (1024 max for depth 10), multi-page snapshot reconstruction,
	// and 1025th member rejection.
	CreateGroup(cross(cur), 500, SupportedDepth, admin)
	for i := 0; i < MaxGroupMembers; i++ {
		hexC := strings.Repeat("00", 30) + toHex2(byte(i>>8)) + toHex2(byte(i&0xff))
		if i == 0 {
			hexC = strings.Repeat("00", 31) + "01"
		}
		if i == 1 {
			hexC = strings.Repeat("00", 30) + "0400"
		}
		AddMember(cross(cur), 500, hexC)
	}
	assertPanics(t, "1025th member exceeds depth-10 capacity", func() {
		AddMember(cross(cur), 500, strings.Repeat("00", 30)+"0500")
	})
	if GetGroupMemberCount(500) != MaxGroupMembers {
		t.Fatalf("expected %d members, got %d", MaxGroupMembers, GetGroupMemberCount(500))
	}
	PublishRoot(cross(cur), 500, strings.Repeat("00", 31)+"aa")
	CreatePoll(cross(cur), 504, 500, "Full 1024 Snapshot Poll", "Yes,No", 0, 0)
	if GetPollSnapshotCount(504) != MaxGroupMembers {
		t.Fatalf("expected snapshot count %d, got %d", MaxGroupMembers, GetPollSnapshotCount(504))
	}

	// Reconstruct all 1024 commitments across 11 pages (100 per page).
	var collected []string
	for offset := 0; offset < MaxGroupMembers; offset += MaxPageSize {
		page := GetPollCommitmentsPaged(504, offset, MaxPageSize)
		if page == "" {
			t.Fatalf("unexpected empty page at offset %d", offset)
		}
		collected = append(collected, strings.Split(page, "\n")...)
	}
	if len(collected) != MaxGroupMembers {
		t.Fatalf("expected %d paginated commitments, got %d", MaxGroupMembers, len(collected))
	}
	if GetPollCommitmentsPaged(504, MaxGroupMembers, MaxPageSize) != "" {
		t.Fatalf("expected empty page past end")
	}

	// Invalid pagination offsets/limits safely return empty without allocation.
	if GetPollCommitmentsPaged(504, -1, 10) != "" {
		t.Fatalf("expected empty for negative offset")
	}
	if GetPollCommitmentsPaged(504, 0, 0) != "" {
		t.Fatalf("expected empty for zero limit")
	}
	if GetPollCommitmentsPaged(504, 0, MaxPageSize+1) != "" {
		t.Fatalf("expected empty for oversized limit")
	}
	if ListPollsPaged(-1, 10) != "" {
		t.Fatalf("expected empty for negative poll page")
	}
	if ListPollsPaged(0, 10) == "" {
		t.Fatalf("expected non-empty poll list")
	}

	// Delimiter injection rejected in title and optionsCSV.
	assertPanics(t, "delimiter in title", func() {
		CreatePoll(cross(cur), 505, 1, "Bad|Title", "Yes,No", 0, 0)
	})
	assertPanics(t, "newline in optionsCSV", func() {
		CreatePoll(cross(cur), 505, 1, "Good", "Yes\n,No", 0, 0)
	})

	// SnapshotMemberCount freezes published member count, NOT post-PublishRoot AddMember additions.
	CreateGroup(cross(cur), 501, SupportedDepth, admin)
	AddMember(cross(cur), 501, strings.Repeat("00", 31)+"11")
	PublishRoot(cross(cur), 501, strings.Repeat("00", 31)+"bb")
	AddMember(cross(cur), 501, strings.Repeat("00", 31)+"22") // added AFTER PublishRoot
	CreatePoll(cross(cur), 506, 501, "Snapshot Consistency Poll", "Yes,No", 0, 0)
	if GetPollSnapshotCount(506) != 1 {
		t.Fatalf("expected snapshot count 1 (frozen at PublishRoot), got %d", GetPollSnapshotCount(506))
	}

	// Scheduled, open, expired, and closed poll status reporting.
	CreatePoll(cross(cur), 507, 501, "Scheduled Poll", "Yes,No", 9999999, 10000000)
	if st := GetPollStatus(507); st != "scheduled" {
		t.Fatalf("expected scheduled, got %s", st)
	}
	if st := GetPollStatus(506); st != "open" {
		t.Fatalf("expected open, got %s", st)
	}
	ClosePoll(cross(cur), 506)
	if st := GetPollStatus(506); st != "closed" {
		t.Fatalf("expected closed, got %s", st)
	}
	CreatePoll(cross(cur), 508, 501, "Expired Poll", "Yes,No", 0, 1)
	if st := GetPollStatus(508); st != "expired" {
		t.Fatalf("expected expired, got %s", st)
	}
}

func TestVoteWorstCaseSingleOps(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(admin))
	// Measure individual worst-case operations separately:
	var opts32 []string
	for i := 0; i < MaxOptions; i++ {
		opts32 = append(opts32, "o"+strconv.Itoa(i))
	}
	CreatePoll(cross(cur), 600, 500, strings.Repeat("x", MaxTitleLen), strings.Join(opts32, ","), 0, 0)
	_ = GetPollCommitmentsPaged(504, 0, MaxPageSize)
	_ = ListPollsPaged(0, MaxPageSize)
}

func toHex2(b byte) string {
	const hexDigits = "0123456789abcdef"
	return string([]byte{hexDigits[b>>4], hexDigits[b&0x0f]})
}
