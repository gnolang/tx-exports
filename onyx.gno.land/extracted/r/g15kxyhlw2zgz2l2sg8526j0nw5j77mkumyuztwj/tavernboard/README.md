# Tavern Board

An on-chain forum/board for Gno.land where posts and replies are chain state and authors earn GNOT tips.

## Features

- **Posts & Replies**: Create posts with title and body, reply to posts
- **GNOT Tips**: Tip posts and replies with ugnot (micro-GNOT) — tips land straight in the author's balance, with any leftover send refunded to the tipper
- **Per-Author Balances**: Track total tips received by each author
- **Tip Leaderboard**: Front page ranks posts by total tips received
- **Pure Gno**: Deterministic, no goroutines, no os, no networking; Gno stdlib imports only (`chain`, `chain/banker`, `chain/runtime/unsafe`, `errors`, `strconv`, `strings`, `time`)

## Quick Start (Local Development)

### Prerequisites

- Go 1.27.4+
- Gno toolchain v1.8.0 (`gno`, `gnokey`, `gnodev`, `gnoweb`) — see https://github.com/gnolang/gno

```bash
export PATH="$HOME/.gno/bin:$PATH"
export GNOROOT="$HOME/.gno/src"
```

### Run Tests

From the workspace root (the `gnowork.toml` one level up lets `gno test` resolve the realm package locally for the filetest):

```bash
cd tavern-board
gno test ./...
```

8 unit tests + 1 filetest (tip flows, leaderboard, refund). All pass (verified on Gno v1.8.0).

### Run Locally with gnodev

```bash
gnodev .
```

Open http://127.0.0.1:8888/r/tavernboard to see the rendered board. The default account (`g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5`) is funded with ugnot; recover its key from the mnemonic gnodev prints, then call the realm:

```bash
# Create a post (gas-wanted must be >= ~5,000,000; a call uses ~3,000,000 gas)
gnokey maketx call -pkgpath gno.land/r/tavernboard -func CreatePost \
  -args "Hello" -args "First post" \
  -gas-fee 1000000ugnot -gas-wanted 5000000 -remote http://localhost:26657 <key>

# Tip post 1 with 1000 ugnot (attach the tip with -send)
gnokey maketx call -pkgpath gno.land/r/tavernboard -func TipPost \
  -args 1 -args 1000 -send 1000ugnot \
  -gas-fee 1000000ugnot -gas-wanted 5000000 -remote http://localhost:26657 <key>
```

Verified on gnodev: CreatePost (height 3), CreateReply (height 5), TipPost 1000ugnot (height 7); `GetPost(1)` shows TipTotal 1000, ReplyCount 1; front page and `:post/1` render correctly.

## Deployment

### Testnet (Onyx)

- **Chain ID**: `onyx-1`
- **Realm**: `gno.land/r/tavernboard`
- **Gnoweb**: https://onyx.testnets.gno.land/r/tavernboard
- **Explorer**: https://onyx.testnets.gno.land

### Deploy Steps

1. Create a testnet-only key:
   ```bash
   gnokey add tavern-board-testnet
   ```

2. Fund the key with test GNOT from the faucet:
   ```bash
   # Visit https://faucet.onyx.testnets.gno.land and request funds for your address
   # (web flow with captcha)
   ```

3. Deploy the realm:
   ```bash
   gnokey maketx addpkg \
     -pkgpath gno.land/r/tavernboard \
     -pkgdir . \
     -gas-fee 2000ugnot \
     -gas-wanted 10000000 \
     -chainid onyx-1 \
     -remote https://rpc.onyx.testnets.gno.land:443 \
     tavern-board-testnet
   ```
   Raise `-gas-wanted` if the simulation reports out of gas.

## Project Structure

```
gnome-tavern/
├── gnowork.toml      # workspace root (lets gno test resolve the realm locally)
└── tavern-board/
    ├── realm.gno          # Main realm implementation (Gno v1.8 API)
    ├── realm_test.gno     # Unit tests (posts, replies, render)
    ├── filetests/
    │   └── z_tip_filetest.gno  # Filetest (tip flows, leaderboard, refund)
    ├── gnomod.toml        # Module configuration (gno.land/r/tavernboard)
    ├── README.md          # This file
    ├── LICENSE            # MIT License
    └── BUILD-NOTES.md     # Build notes and verification log
```

## Realm Functions

| Function | Description |
|----------|-------------|
| `CreatePost(title, body)` | Create a new post, returns post ID |
| `CreateReply(postID, body)` | Add a reply to a post, returns reply ID |
| `TipPost(postID, amount)` | Tip a post author with ugnot (attach with `-send <amount>ugnot`) |
| `TipReply(postID, replyID, amount)` | Tip a reply author with ugnot (attach with `-send`) |
| `GetPost(postID)` | Get a post by ID |
| `GetReplies(postID)` | Get all replies for a post |
| `GetPosts()` | Get all posts sorted by tips (leaderboard) |
| `GetAuthorTips(author)` | Get total tips received by an author |
| `Render(path)` | Gnoweb entry point — `""` = front page, `"post/<id>"` = post detail |

## License

MIT License - see [LICENSE](LICENSE) for details.

## Hackathon

Built for the Gnome Tavern Hackathon (DoraHacks + Gno.land).
