package kewrchess

import (
	"gno.land/p/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/chess"
	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	output := "# ♟️ KewrChess - Gno.land Edition\n\n"
	output += "---\n\n"

	// On-chain Matchmaking Queue Status
	if len(matchmakingQueue) > 0 {
		output += ufmt.Sprintf("### ⏳ Matchmaking Queue (%d players waiting)\n\n", len(matchmakingQueue))
		for i, qAddr := range matchmakingQueue {
			output += ufmt.Sprintf("- Position #%d: `%s`\n", i+1, qAddr)
		}
		output += "\n---\n\n"
	}

	if len(games) == 0 {
		output += "Never Sold His Soul wkwk!\n\n"
		output += "No active chess games found.\n"
		return output
	}

	for _, g := range games {
		output += ufmt.Sprintf("### ⚔️ Game #%d\n", g.id)

		statusText := "`PLAYING` 🟢"
		if g.status == "WHITE_WON" {
			if g.resignedBy != "" {
				statusText = "`WHITE WON (Black Resigned)` 🏳️ 🏆"
			} else {
				statusText = "`WHITE WON` 🏆"
			}
		} else if g.status == "BLACK_WON" {
			if g.resignedBy != "" {
				statusText = "`BLACK WON (White Resigned)` 🏳️ 🏆"
			} else {
				statusText = "`BLACK WON` 🏆"
			}
		} else if g.status == "DRAW" {
			statusText = "`DRAW` 🤝"
		}

		output += ufmt.Sprintf("> **Status**: %s\n", statusText)

		if g.settledBy != "" {
			output += ufmt.Sprintf("> ⛓️ **On-Chain Settlement**: Settled by `%s`\n", g.settledBy)
		}

		if g.status == "PLAYING" && g.drawOfferedBy != "" {
			offeredColor := "Black"
			if g.drawOfferedBy == g.white {
				offeredColor = "White"
			}
			output += ufmt.Sprintf("> 🤝 **Draw Offer**: Offered by %s (`%s`)\n", offeredColor, g.drawOfferedBy)
		}

		turnText := "Black (⚫)"
		if g.isWhiteTurn {
			turnText = "White (⚪)"
		}
		output += ufmt.Sprintf("> **Turn**: %s\n>\n", turnText)
		output += ufmt.Sprintf("> * ⚪ **White**: `%s`\n", g.white)
		output += ufmt.Sprintf("> * ⚫ **Black**: `%s`\n\n", g.black)

		output += "| | | | | | | | |\n"
		output += "| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n"

		for r := 0; r < 8; r++ {
			output += "|"

			for c := 0; c < 8; c++ {
				piece := g.board[r][c]
				if piece == "." {
					square := "⬜"
					if (r+c)%2 != 0 {
						square = "🟩"
					}
					output += ufmt.Sprintf(" <span style=\"font-size:32px;\">%s</span> |", square)
				} else {
					emoji := chess.GetPieceEmoji(piece)
					output += ufmt.Sprintf(" <span style=\"font-size:32px;\">%s</span> |", emoji)
				}
			}
			output += "\n"
		}
		output += "\n---\n\n"
	}

	output += "### 💡 How to Play:\n"
	output += "```bash\n"
	output += "# Join automatic matchmaking queue (Find Match on-chain):\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess JoinQueue \\\n"
	output += "  --args \"[your_address]\"\n\n"
	output += "# Leave / cancel matchmaking queue:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess LeaveQueue \\\n"
	output += "  --args \"[your_address]\"\n\n"
	output += "# Standard move (default auto-promotion to Queen):\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess MakeMove \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID] \\\n"
	output += "  --args [fromRow] --args [fromCol] \\\n"
	output += "  --args [toRow] --args [toCol]\n\n"
	output += "# Move with promotion choice (Q = Queen, N = Knight, R = Rook, B = Bishop):\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess MakeMovePromote \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID] \\\n"
	output += "  --args [fromRow] --args [fromCol] \\\n"
	output += "  --args [toRow] --args [toCol] \\\n"
	output += "  --args \"N\"\n\n"
	output += "# Resign:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess Resign \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Offer a draw:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess OfferDraw \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Accept draw offer:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess AcceptDraw \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Decline draw offer:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess DeclineDraw \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Final settlement (Officially settle match result on-chain via move verification):\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess SettleGame \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID] \\\n"
	output += "  --args \"e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7\"   # Full UCI chess move history\n\n"
	output += "# Confirm settlement result by opponent (Instant approval):\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess ConfirmSettlement \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Dispute fraudulent settlement proposal:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess DisputeSettlement \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n\n"
	output += "# Start turn timer if opponent is AFK / rage quits:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess StartTurnTimer \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID] \\\n"
	output += "  --args \"[current_moves_uci]\"\n\n"
	output += "# Claim win due to opponent abandonment / timeout:\n"
	output += "gno call gno.land/r/g1g7dna0gp4nec5rza4q25htj0cjgswrxefp37ep/kewrchess ClaimTimeout \\\n"
	output += "  --args \"[your_address]\" \\\n"
	output += "  --args [gameID]\n"
	output += "```\n"

	return output
}
