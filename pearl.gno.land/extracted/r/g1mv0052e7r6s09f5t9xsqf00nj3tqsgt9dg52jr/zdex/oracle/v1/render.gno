package oracle

func Render(path string) string {
	out := "# zdex oracle v1 (Ping)\n\n"
	out += "Opt-in TWAP sidecar. Does not sit in SwapExactIn. Keeper or user calls `Ping(poolID)`; `Observe(poolID, agoBlocks)` is query-only.\n\n"
	out += "Not a price feed for AmountOut. Not financial advice. Pearl testnet.\n"
	return out
}
