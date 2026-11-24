// PKGPATH: gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/main
package main

import (
	"chain"
	"testing"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	_ "gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/judges/sortnums"
	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/cheat"
	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/sort1"
)

// A judged challenge: the inputs are generated when the solution is revealed,
// so a lookup table cannot pass, while a real sort can.
func main(cur realm) {
	poster := address("g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe")
	cheater := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	honest := address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	boardAddr := chain.PackageAddress("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet")

	println(gauntlet.JudgesJSON())

	fund(boardAddr, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	id := gauntlet.PostJudged(cross(cur), "Sort the numbers",
		"Sort a comma-separated list of integers ascending.",
		"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/judges/sortnums", "3,1,2 => 1,2,3", 6, 0, 30)

	// The cheater commits first, so they would win if their code passed.
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(cheater))
	gauntlet.Commit(cross(cur), id, gauntlet.HashFor("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/cheat", "s1"))
	testing.SetRealm(testing.NewUserRealm(honest))
	gauntlet.Commit(cross(cur), id, gauntlet.HashFor("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/sort1", "s2"))

	cheat.Submit(cross(cur), id, "s1")
	println("after the cheat reveals, status:", status(id))

	sort1.Submit(cross(cur), id, "s2")
	println("after the honest solution reveals, status:", status(id))
	println(gauntlet.ChallengeJSON(id))
}

func status(id uint64) string {
	j := gauntlet.ChallengeJSON(id)
	i := indexOf(j, `"status":"`)
	rest := j[i+10:]
	return rest[:indexOf(rest, `"`)]
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func fund(to address, amount int64) {
	coins := chain.Coins{{Denom: "ugnot", Amount: amount}}
	testing.IssueCoins(to, coins)
	testing.SetOriginSend(coins)
}

// Output:
// [{"path":"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/judges/sortnums","name":"Sort numbers","about":"Sort comma-separated integers ascending. 8 random lists of 1-40 numbers.","uses":0}]
// after the cheat reveals, status: open
// after the honest solution reveals, status: won
// {"id":1,"title":"Sort the numbers","spec":"Sort a comma-separated list of integers ascending.","status":"won","poster":"g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe","reward":1000000,"pot":1000000,"bond":0,"boosts":0,"forfeited":0,"created":1234567890,"deadline":1234589490,"window":1800,"judge":"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/judges/sortnums","cases":[{"in":"3,1,2","want":"1,2,3"}],"attempts":[{"seq":1,"solver":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5","hash":"14a14753d77e6078e2b710c61f8ac68ccb3ef12b868f87dac8acc9840ab493a1","committed":1234567890,"state":"failed","pkgpath":"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/cheat","passed":0,"total":8,"failIn":"-229,-517,520,-505","failGot":"0","failWant":"","winner":false},{"seq":2,"solver":"g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0","hash":"d043c782ab6328d7842e56e3c51d35d8950f9dd155f7efa4df3d735afc1c91a7","committed":1234567890,"state":"passed","pkgpath":"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/sort1","passed":9,"total":9,"failIn":"","failGot":"","failWant":"","winner":true}]}
