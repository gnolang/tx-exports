package veil_vote

import (
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
		Vote(cross(cur), 42, 10, group1ExpandedRoot, "14b02b9b6d38653c8fb438d3888b78ef3618f367e5251da859cf9b8bcb59ee7a", 1, "1c650691cd078bd3c8e29c428733eb7fcb79f5db477090a6072a4e85591525090b498418dce27f26895403a0b63c8fbe664159b5e7e09cf53f9b5ffa5ea86ed1", "1618484f4349c198e89dce72c717c6b6941ea7be55f2f921225c4e09f67527391064fbe06bcb56773b925b411896ded3dc2645131d9a42487e763ea0eac1ad42024987946ce156210e0312f255f0dc71542f522e9683683af544232df71a4a94095e018e7241d18f51929dd67f603ee191a5559b50f4a441bc9fc3f2f713ca8a", "234f52380b6d0767c593e8c5b4543e5c4e5c72db580b0d9ae162fc89a2b2ccc202adb18603e4cd71871bb055905a4ebec0347cb2ff93d0aa099d39f887120ff5")
	})

	// Modified vote choice rejected AND failed verification does NOT consume nullifier.
	assertPanics(t, "modified vote choice", func() {
		Vote(cross(cur), 42, 10, group1Root, "0f0c52b5f0b816e1a40729aee24faac212639a7f8078148652636b40a0e2944f", 2, "21dac493c530160628c27f169bbd6f0b75e29b469381dcfe599822a966d5579819ea9a3469c5fc12473b444e43c4ceb02469b7b2957835455f8f29b9af8280aa", "07eeaf245e582d73db832d24e82b8a20b957e9889f9b23fa9aa4fc2ffb7ba0aa1f1ff11bdc02c814c4676a0ff62b97fdf77e895b87ab35659218a89fb2518d4c28d16fb0a0f2ce2309f7204b552a972c6803bd912f3d00976ad20db49378e3d0086f44c169812596bd749758ae01d7a7ea7dc4fae8e572e2326e28a64c352472", "181dae9bd99ca1f15d3d6c8063828f2d016e961692deb2abc94b948e4205d8b429db5642df7178455c63774764713bc8857d68331ef8cfd847108b206d440ce6")
	})
	if GetPollTally(42, 2) != 0 {
		t.Fatalf("tally updated on failed vote")
	}

	// Previously eligible member id0 using frozen root succeeds!
	res := Vote(cross(cur), 42, 10, group1Root, "0f0c52b5f0b816e1a40729aee24faac212639a7f8078148652636b40a0e2944f", 1, "21dac493c530160628c27f169bbd6f0b75e29b469381dcfe599822a966d5579819ea9a3469c5fc12473b444e43c4ceb02469b7b2957835455f8f29b9af8280aa", "07eeaf245e582d73db832d24e82b8a20b957e9889f9b23fa9aa4fc2ffb7ba0aa1f1ff11bdc02c814c4676a0ff62b97fdf77e895b87ab35659218a89fb2518d4c28d16fb0a0f2ce2309f7204b552a972c6803bd912f3d00976ad20db49378e3d0086f44c169812596bd749758ae01d7a7ea7dc4fae8e572e2326e28a64c352472", "181dae9bd99ca1f15d3d6c8063828f2d016e961692deb2abc94b948e4205d8b429db5642df7178455c63774764713bc8857d68331ef8cfd847108b206d440ce6")
	if res != "RECORDED" || GetPollTally(42, 1) != 1 {
		t.Fatalf("valid vote failed: res=%s tally=%d", res, GetPollTally(42, 1))
	}

	// Double vote in same poll rejected.
	assertPanics(t, "double vote in same poll", func() {
		Vote(cross(cur), 42, 10, group1Root, "0f0c52b5f0b816e1a40729aee24faac212639a7f8078148652636b40a0e2944f", 1, "21dac493c530160628c27f169bbd6f0b75e29b469381dcfe599822a966d5579819ea9a3469c5fc12473b444e43c4ceb02469b7b2957835455f8f29b9af8280aa", "07eeaf245e582d73db832d24e82b8a20b957e9889f9b23fa9aa4fc2ffb7ba0aa1f1ff11bdc02c814c4676a0ff62b97fdf77e895b87ab35659218a89fb2518d4c28d16fb0a0f2ce2309f7204b552a972c6803bd912f3d00976ad20db49378e3d0086f44c169812596bd749758ae01d7a7ea7dc4fae8e572e2326e28a64c352472", "181dae9bd99ca1f15d3d6c8063828f2d016e961692deb2abc94b948e4205d8b429db5642df7178455c63774764713bc8857d68331ef8cfd847108b206d440ce6")
	})

	// Same identity CAN vote in distinct poll (poll 43).
	res2 := Vote(cross(cur), 43, 10, group1Root, "206099ed8b08adceed08a56cfd24d2830867fac67dc59bc0a6c46d6c8882ca69", 2, "0a4976f8cb9a1108b71847612b229d7bfb43d455c7ccfd225fdd975a8a1196dc238a8f0bcae9effb42b900b84c93830512165fb4eeb0eb03ab8f396ec0e488b9", "094f945794d84e2d7bd1e8ad419ffa63d7e0c2a9e8502e1ca5fb25c42d4e07952685cc9d81754f6b64c732bf18ad12a649c06e55507a2693f0f9b35998cea77b00c1de03107fafcc90883cde927ac22e858e6b6b332ddc13a748a38c1144b6f123c91d6e0d65103f81143e02de2f5bf800374884935838f7e8336657e0e586ab", "03ae4e4145c9cf024b22654466e206ea12d1bd4783f10ecb0ba74b1e46116761202012f3f2a0462567987f8219725a36f84aa63879565e3808054d5aeed9f279")
	if res2 != "RECORDED" || GetPollTally(43, 2) != 1 {
		t.Fatalf("distinct poll vote failed")
	}

	// Proof for another poll (poll 43) rejected in poll 42.
	assertPanics(t, "proof for another poll", func() {
		Vote(cross(cur), 42, 10, group1Root, "206099ed8b08adceed08a56cfd24d2830867fac67dc59bc0a6c46d6c8882ca69", 2, "0a4976f8cb9a1108b71847612b229d7bfb43d455c7ccfd225fdd975a8a1196dc238a8f0bcae9effb42b900b84c93830512165fb4eeb0eb03ab8f396ec0e488b9", "094f945794d84e2d7bd1e8ad419ffa63d7e0c2a9e8502e1ca5fb25c42d4e07952685cc9d81754f6b64c732bf18ad12a649c06e55507a2693f0f9b35998cea77b00c1de03107fafcc90883cde927ac22e858e6b6b332ddc13a748a38c1144b6f123c91d6e0d65103f81143e02de2f5bf800374884935838f7e8336657e0e586ab", "03ae4e4145c9cf024b22654466e206ea12d1bd4783f10ecb0ba74b1e46116761202012f3f2a0462567987f8219725a36f84aa63879565e3808054d5aeed9f279")
	})

	// Proof for another group (group 2) rejected in group 1 poll 42.
	assertPanics(t, "proof for another group", func() {
		Vote(cross(cur), 42, 10, group2Root, "07e71ba3fe8e6acf161f44c11587a136cad254f5e813f08c468486244da0728e", 1, "192612de90a444d85a37d32f3063cebdc50a58eae569a5c469f71b9fc149625728f7e9df5c94645f5b1dbd5ec22f2a439eccc2fbc5912b76ce6ce4ec6f92a4b5", "05038e5c2b00855dc1ea5b778433c00a51c24e746e2b3fefdc3341caa8a4524104cf167e530e39e2d59201d7e2b1b669f493b2a474d9d8a9db4a57c9d9205aa60b40c51156c8c0ac2f83c3e9d1e10eba8cff5e5e99e08fdb7dce50f9d7d84b4a203d2a99f40d6c7445910a9b57fc227d32dcece987339f0295bb4dfc7641de00", "0a839d52ca3e085f9b4e9e58fcb43cf38408b5792a46d012490c7c378e5e5ac62cfbc72162ea31a0329b96193c373b56a0bf1f69e31be68c96b4d74bb1a695f6")
	})

	// Arbitrary root rejected.
	assertPanics(t, "arbitrary root", func() {
		Vote(cross(cur), 42, 10, nonMemComm, "06c12d98e0c3d0a5b060108f5932ec1675181fb55dded81760b07fd6924ab2e3", 2, "0f6b396050c39fa71a7f09caef79c16761d5401263ec7a8547fa8ef6358343b0065c58403ad114ff583edfc4a8963721be95f1e344ccc9044d7dd12b9efc517a", "2a852ee181ed5033fac0e7546acc4eb822b1065dd898c7745f2735d87edf509c29eacc42cf965cb55e24467931a475923469c760de808c0e78872c0953876aa00b31d57dbbb9aad294145d5a4c24b9d828218cd43aa9ecbdd6c384fe2db2e35f2cef3ec2fad7ee00421fcddd4cd63ee384480d3f2a58b4d6fdcca4001c033ead", "0f1b38d2277c939fce8c12a7f90fdd03fd0c369975925483378ff2bb4683fe012f9d0f9984d56f1f7387a8467ff989dd7cf8108e74c9263a0cf10f31c59ea481")
	})

	// Unsupported depth rejected.
	assertPanics(t, "unsupported depth", func() {
		Vote(cross(cur), 42, 20, group1Root, "06c12d98e0c3d0a5b060108f5932ec1675181fb55dded81760b07fd6924ab2e3", 2, "0f6b396050c39fa71a7f09caef79c16761d5401263ec7a8547fa8ef6358343b0065c58403ad114ff583edfc4a8963721be95f1e344ccc9044d7dd12b9efc517a", "2a852ee181ed5033fac0e7546acc4eb822b1065dd898c7745f2735d87edf509c29eacc42cf965cb55e24467931a475923469c760de808c0e78872c0953876aa00b31d57dbbb9aad294145d5a4c24b9d828218cd43aa9ecbdd6c384fe2db2e35f2cef3ec2fad7ee00421fcddd4cd63ee384480d3f2a58b4d6fdcca4001c033ead", "0f1b38d2277c939fce8c12a7f90fdd03fd0c369975925483378ff2bb4683fe012f9d0f9984d56f1f7387a8467ff989dd7cf8108e74c9263a0cf10f31c59ea481")
	})

	// Invalid vote option rejected.
	assertPanics(t, "invalid vote option", func() {
		Vote(cross(cur), 42, 10, group1Root, "06c12d98e0c3d0a5b060108f5932ec1675181fb55dded81760b07fd6924ab2e3", 99, "0f6b396050c39fa71a7f09caef79c16761d5401263ec7a8547fa8ef6358343b0065c58403ad114ff583edfc4a8963721be95f1e344ccc9044d7dd12b9efc517a", "2a852ee181ed5033fac0e7546acc4eb822b1065dd898c7745f2735d87edf509c29eacc42cf965cb55e24467931a475923469c760de808c0e78872c0953876aa00b31d57dbbb9aad294145d5a4c24b9d828218cd43aa9ecbdd6c384fe2db2e35f2cef3ec2fad7ee00421fcddd4cd63ee384480d3f2a58b4d6fdcca4001c033ead", "0f1b38d2277c939fce8c12a7f90fdd03fd0c369975925483378ff2bb4683fe012f9d0f9984d56f1f7387a8467ff989dd7cf8108e74c9263a0cf10f31c59ea481")
	})

	// Multiple distinct members can vote successfully.
	res3 := Vote(cross(cur), 42, 10, group1Root, "06c12d98e0c3d0a5b060108f5932ec1675181fb55dded81760b07fd6924ab2e3", 2, "0f6b396050c39fa71a7f09caef79c16761d5401263ec7a8547fa8ef6358343b0065c58403ad114ff583edfc4a8963721be95f1e344ccc9044d7dd12b9efc517a", "2a852ee181ed5033fac0e7546acc4eb822b1065dd898c7745f2735d87edf509c29eacc42cf965cb55e24467931a475923469c760de808c0e78872c0953876aa00b31d57dbbb9aad294145d5a4c24b9d828218cd43aa9ecbdd6c384fe2db2e35f2cef3ec2fad7ee00421fcddd4cd63ee384480d3f2a58b4d6fdcca4001c033ead", "0f1b38d2277c939fce8c12a7f90fdd03fd0c369975925483378ff2bb4683fe012f9d0f9984d56f1f7387a8467ff989dd7cf8108e74c9263a0cf10f31c59ea481")
	if res3 != "RECORDED" || GetPollTally(42, 2) != 1 {
		t.Fatalf("second member vote failed")
	}

	// Closed poll rejects submissions.
	testing.SetRealm(testing.NewUserRealm(admin))
	ClosePoll(cross(cur), 43)
	testing.SetRealm(testing.NewUserRealm(voter))
	assertPanics(t, "closed poll", func() {
		Vote(cross(cur), 43, 10, group1Root, "06c12d98e0c3d0a5b060108f5932ec1675181fb55dded81760b07fd6924ab2e3", 2, "0f6b396050c39fa71a7f09caef79c16761d5401263ec7a8547fa8ef6358343b0065c58403ad114ff583edfc4a8963721be95f1e344ccc9044d7dd12b9efc517a", "2a852ee181ed5033fac0e7546acc4eb822b1065dd898c7745f2735d87edf509c29eacc42cf965cb55e24467931a475923469c760de808c0e78872c0953876aa00b31d57dbbb9aad294145d5a4c24b9d828218cd43aa9ecbdd6c384fe2db2e35f2cef3ec2fad7ee00421fcddd4cd63ee384480d3f2a58b4d6fdcca4001c033ead", "0f1b38d2277c939fce8c12a7f90fdd03fd0c369975925483378ff2bb4683fe012f9d0f9984d56f1f7387a8467ff989dd7cf8108e74c9263a0cf10f31c59ea481")
	})

	// Cross-app and cross-network replay rejected at Primitives layer.
	rBytes, _ := decodeHex32(group1Root)
	nBytes, _ := decodeHex32("0f0c52b5f0b816e1a40729aee24faac212639a7f8078148652636b40a0e2944f")
	pf, _ := groth16.ParseProofHex("21dac493c530160628c27f169bbd6f0b75e29b469381dcfe599822a966d5579819ea9a3469c5fc12473b444e43c4ceb02469b7b2957835455f8f29b9af8280aa", "07eeaf245e582d73db832d24e82b8a20b957e9889f9b23fa9aa4fc2ffb7ba0aa1f1ff11bdc02c814c4676a0ff62b97fdf77e895b87ab35659218a89fb2518d4c28d16fb0a0f2ce2309f7204b552a972c6803bd912f3d00976ad20db49378e3d0086f44c169812596bd749758ae01d7a7ea7dc4fae8e572e2326e28a64c352472", "181dae9bd99ca1f15d3d6c8063828f2d016e961692deb2abc94b948e4205d8b429db5642df7178455c63774764713bc8857d68331ef8cfd847108b206d440ce6")
	if err := semaphore.VerifyAndConsume(vks, groups, semaphore.NewNullifierSet(), 1, 10, rBytes, nBytes, semaphore.Uint64ToBE32(1), semaphore.DomainScopeFull("onyx-1", "gno.land/r/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/veil_vote/v2", 1, 42), pf); err == nil {
		t.Fatalf("expected error for cross-network replay")
	}
}
