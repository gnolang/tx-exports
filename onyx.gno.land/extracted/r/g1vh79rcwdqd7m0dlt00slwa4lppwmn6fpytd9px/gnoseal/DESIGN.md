# GnoSeal — Design

Verifiable onchain certificates on Gno.land. An issuer (hackathon, course,
event, bounty program) creates a completion record for a recipient address.
The record is non-transferable, publicly verifiable by anyone through the
realm's Render pages, and revocable only by its original issuer, with the
revocation reason written on chain.

- Module: `gno.land/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal`
- Package: `gnoseal` (this directory)
- Network: Onyx testnet, chain ID `onyx-1`
- Issuer/deployer address: `g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px` (key `tavern-deployer`)
- Web surface after deploy: https://onyx.testnets.gno.land/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal

## Data model

Realm state (persisted automatically after each transaction):

```go
type Certificate struct {
    ID           uint64  // sequential, starts at 1, never reused
    Issuer       address // caller that created the certificate
    Recipient    address // bech32-validated at creation
    Title        string  // trimmed, 1..120 bytes
    Note         string  // 0..560 bytes
    Height       int64   // block height at issuance (runtime.ChainHeight)
    Revoked      bool    // set once by RevokeCertificate
    RevokeReason string  // 1..280 bytes once Revoked is true
}

var certs       []*Certificate          // certs[i] holds ID i+1 (issuance order)
var byRecipient = map[address][]uint64{} // recipient -> its certificate IDs, in issuance order
```

Certificates are never deleted or edited; revocation is a flag plus a
reason, so the full history stays auditable. There are no payments and no
transfer path: a certificate is a record, not an asset.

## Functions

Crossing functions (first parameter `realm`; callable via `gnokey maketx
call` and the gnoweb Actions tab). Caller identity is always
`cur.Previous().Address()`, per the current interrealm guidance (never
`chain/runtime/unsafe` stack-walking):

| Function | Behavior |
| --- | --- |
| `CreateCertificate(cur realm, recipient address, title string, note string) uint64` | Validates recipient (`address.IsValid`), title non-empty after trim and ≤ 120 bytes, note ≤ 560 bytes. Records the caller as issuer and the current block height. Returns the new sequential ID. |
| `RevokeCertificate(cur realm, id uint64, reason string)` | Panics unless the certificate exists, the caller is its original issuer, and it is not already revoked. Reason must be non-empty after trim and ≤ 280 bytes. Sets `Revoked` and stores the reason. |

Read functions (plain, callable via `vm/qeval` / `vm/qrender`):

| Function | Behavior |
| --- | --- |
| `Count() uint64` | Total certificates ever issued, including revoked ones. |
| `GetCertificate(id uint64) Certificate` | A copy of the certificate; panics (`gnoseal: certificate not found`) for ID 0 or an unissued ID. |
| `CertificatesOf(recipient address) []uint64` | Copy of the recipient's certificate IDs in issuance order (the `byRecipient` index). |

All validation panics happen before any state write, so a rejected call
leaves storage untouched.

## Render routes

`Render(path string) string` returns Markdown for gnoweb. Stored titles,
notes, and reasons are user-supplied, so they pass through
`sanitize.InlineText` (`gno.land/p/nt/markdown/sanitize/v0`) before being
written into the output; path segments are never echoed raw. Bad routes and
bad IDs render friendly pages instead of panicking.

| Path | Page |
| --- | --- |
| `""` | Intro, total issued, lookup hints, and the most recent certificates (newest first, up to 20), each linking to its detail page and marked if revoked. |
| `cert/<id>` | One certificate in full: title, recipient, issuer, issuance block height, status (Valid / Revoked), revoke reason when revoked, note when present, and a link to the recipient's collection page. Unknown or non-numeric IDs show "Certificate not found". |
| `addr/<address>` | All certificates issued to that address (newest first) with links. Invalid addresses and addresses without certificates get a clear message. |
| anything else | "Unknown page" with a link home. |

Links use the gnoweb form `/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal:cert/<id>`
(resp. `:addr/<address>`).

## Dependencies

- Realm code imports only the stdlib (`chain/runtime`, `strings`,
  `strconv`) plus `gno.land/p/nt/markdown/sanitize/v0` for Render output
  sanitization. That package is present on Onyx (its file list answers over
  the Onyx RPC).
- Test files additionally import `gno.land/p/nt/uassert/v0` (with its deps
  `gno.land/p/nt/ufmt/v0` and `gno.land/p/onbloc/diff/v0`) to assert
  cross-call aborts via the VM's `revive` mechanism.
- Local resolution note: this VM cannot reliably download packages over
  RPC (the local relay intermittently 502s and direct TLS fails), so the
  four packages above were seeded into the local mod cache
  (`~/.config/gno/pkg/mod/`) from the official clone's `examples/` tree,
  together with their `.markers` entries (marker name = the package's
  derived bech32 address). That mirrors exactly what `gno mod download`
  would have written. If the cache is wiped, re-seed the same way or run
  `gno mod download -remote-overrides "gno.land=http://127.0.0.1:26657"`
  with the relay up and retry until it completes.

## Tests

`gno test .` — 14 tests, all passing; `gno lint ./...` clean; `gno fmt`
clean. Coverage: create + read back every field, sequential IDs, invalid
recipient (garbage, empty, bad checksum), empty/whitespace title, title and
note length limits (over-limit rejected, exactly-at-limit accepted),
revoke by issuer, revoke by non-issuer rejected, double revoke rejected,
revoke/get of nonexistent IDs, the per-recipient index, and Render output
for home, certificate detail (valid and revoked states), address page
(populated, empty, invalid), and unknown routes.

Crossing-call panics are asserted with `uassert.AbortsContains` (a crossed
panic is an abort and cannot be caught with `defer`/`recover`);
non-crossing panics (e.g. `GetCertificate`) use `uassert.PanicsContains`.

## Deploy (run later — NOT executed in the MVP task)

Prerequisites, from the deploy-proof lessons in
`~/workspace/gnome-tavern/notes/DEPLOY_PROOF.md`:

1. The local RPC relay must be running (gnokey ignores proxy env vars and
   this VM has no direct egress):

   ```bash
   nohup python3 ~/workspace/gnome-tavern/notes/rpc-relay.py > /tmp/rpc-relay.log 2>&1 &
   ```

2. Signing uses the recovered keyring — the original keyring's password
   was never recorded. Password file (0600, testnet-only throwaway):
   `~/workspace/gnome-tavern/notes/keyring-recovered-password.txt`.
   Never print the mnemonic.

Deploy command (from this directory):

```bash
cd ~/workspace/gnome-tavern/app/gnoseal
cat ~/workspace/gnome-tavern/notes/keyring-recovered-password.txt | \
~/workspace/gnome-tavern/bin/gnokey maketx addpkg \
  -pkgpath "gno.land/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal" \
  -pkgdir . \
  -gas-fee 5000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote http://127.0.0.1:26657 \
  -home ~/workspace/gnome-tavern/notes/keyring-recovered \
  -insecure-password-stdin \
  tavern-deployer
```

Notes for the deploy run:

- The deploy locks a storage deposit of 100 ugnot per byte on top of the
  gas fee (the proof realm locked ~0.32 GNOT); the faucet drip of 100 GNOT
  covers this easily.
- Wrap the call in a retry-on-502 loop: the relay intermittently returns
  502 ("Remote end closed connection without response"). A wrong password
  surfaces as "invalid account password" once the relay is healthy — do
  not confuse the two errors.
- After `OK!` and the tx hash, the package goes through GPAS
  (https://gpas.latest.testnets.gno.land) and is enabled on chain in slow
  batches (hours, per the proof run). Poll
  `gnokey query vm/qrender` for the realm path until it answers instead of
  expecting the gnoweb page to work immediately.
- First calls after enablement (same signing pattern):

  ```bash
  # issue a certificate
  cat ~/workspace/gnome-tavern/notes/keyring-recovered-password.txt | \
  ~/workspace/gnome-tavern/bin/gnokey maketx call \
    -pkgpath "gno.land/r/g1vh79rcwdqd7m0dlt00slwa4lppwmn6fpytd9px/gnoseal" \
    -func "CreateCertificate" \
    -args "<recipient-g1-address>" -args "<title>" -args "<note>" \
    -gas-fee 2000ugnot -gas-wanted 2000000 \
    -chainid onyx-1 -remote http://127.0.0.1:26657 \
    -home ~/workspace/gnome-tavern/notes/keyring-recovered \
    -insecure-password-stdin \
    tavern-deployer
  ```

## Design decisions beyond the original brief

- **Current toolchain APIs, not the retired `std` package.** The brief's
  `std.Address` / std caller patterns map to this toolchain's split
  packages: the builtin `address` type (validated with `IsValid()`),
  `runtime.ChainHeight()` from `chain/runtime` for the issuance height,
  and `cur.Previous().Address()` for caller identity, following the
  clone's `docs/resources/gno-interrealm.md` and its AGENTS.md security
  rules (no `chain/runtime/unsafe` stack-walking beside a `cur` param).
- **Revoke requires a non-empty reason.** The brief said the reason is
  recorded; an empty reason would defeat the product's transparency
  purpose, so it is rejected (trimmed, ≤ 280 bytes).
- **`GetCertificate` returns a copy by value**, never a pointer into realm
  storage, so no caller can hold a mutable reference to stored state.
- **Length caps in bytes** (title 120, note 560, reason 280): simple,
  deterministic, and matched by boundary tests.
- **Storage layout**: a slice for issuance order plus a
  `map[address][]uint64` index, instead of an AVL tree — v1 volumes are
  small, and the map keeps the recipient lookup O(1) without an extra
  dependency.
