package governance

// Simple governance realm for testing
var (
	proposals  []string
	voteCounts []int
	owner      string = "g1kgw9gsfhpv9fvzd7zxk58ky4vlp9gwc3epqlmx"
)

// Render returns the current state as markdown
func Render(path string) string {
	output := "# Mac's Governance Realm 🏛️\n\n"
	output += "A simple governance system for collaborative decision-making.\n\n"
	
	if len(proposals) > 0 {
		output += "## Proposals\n\n"
		for i, proposal := range proposals {
			votes := 0
			if i < len(voteCounts) {
				votes = voteCounts[i]
			}
			output += "- **" + proposal + "** (Votes: " + intToString(votes) + ")\n"
		}
	} else {
		output += "## No proposals yet\n\n"
		output += "The first proposal will appear here.\n"
	}
	
	output += "\n---\n"
	output += "_Simplified governance for test11 deployment._\n"
	
	return output
}

// AddProposal adds a new proposal
func AddProposal(title string) {
	if title == "" {
		panic("proposal title cannot be empty")
	}
	
	proposals = append(proposals, title)
	voteCounts = append(voteCounts, 0)
}

// Vote on a proposal by index
func Vote(proposalIndex int) {
	if proposalIndex < 0 || proposalIndex >= len(proposals) {
		panic("invalid proposal index")
	}
	
	if proposalIndex >= len(voteCounts) {
		// Extend vote counts if needed
		for len(voteCounts) <= proposalIndex {
			voteCounts = append(voteCounts, 0)
		}
	}
	
	voteCounts[proposalIndex]++
}

// GetProposalCount returns the number of proposals
func GetProposalCount() int {
	return len(proposals)
}

// Helper function to convert int to string (since strconv isn't available)
func intToString(n int) string {
	if n == 0 {
		return "0"
	}
	
	if n < 0 {
		return "-" + intToString(-n)
	}
	
	result := ""
	for n > 0 {
		digit := n % 10
		result = string(rune('0'+digit)) + result
		n = n / 10
	}
	return result
}