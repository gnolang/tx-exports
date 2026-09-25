# Settler avatars

This realm's one job is to show off a Settler as a small picture, for anyone who asks.
If an account owns a Settler, this is the place that draws it.

This realm doesn't own or store anything itself; it just looks up a Settler and draws it, on the spot,
whenever it's asked to. Keeping it separate means any other realm or web app on Gno.land can show someone's
Settler next to their name, in a forum post, a leaderboard, or a profile, without having to know anything
about how the art is put together. They just ask this realm for the picture.

The [Settlers nft realm](/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/nft) is what actually hands out the gnomes and keeps
track of who owns what.

## Usage Example

This gives you a Settler image next to the address, ready to write into your own Markdown:

```go
import "gno.land/r/g17khqpukees4237dtn3astzapmp462vjhsz6st4/settlers/avatar"

func RenderUser(addr address) string {
	// Size: 32x32 px, Transparent background: true
	return avatar.Markdown(addr, 32, true) + " " + addr.String()
}
```

`Markdown` returns nothing if the address has no Settler, so there's no need to check first.
`SVG` and `URI` work the same way, and give you the raw picture instead, if that's what you need.
