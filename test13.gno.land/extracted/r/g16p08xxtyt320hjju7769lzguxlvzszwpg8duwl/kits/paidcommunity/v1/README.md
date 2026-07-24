# Kit: Paid Community

Joinable community with admin roles, membership, and posts.

## Functions

| Function | Who | Description |
|----------|-----|-------------|
| `InitAdmin(name, description)` | first caller | Bootstrap |
| `Join(display)` | anyone | Join community |
| `Approve(addr)` | admin | Approve pending |
| `SetPolicy(openJoin, requireApproval, maxMembers)` | admin | Policy |
| `PostMessage(body)` | member | Create post |
| `BanMember(addr)` | admin | Ban user |

## Local

```bash
# from repo root (with Gno toolchain)
gnodev ./gno/p/gnoforge/roles/v0 ./gno/p/gnoforge/membership/v0 ./gno/r/gnoforge/kits/paidcommunity
```

## Deploy sketch

```bash
gnokey maketx addpkg \
  -pkgpath "gno.land/r/<YOUR_ADDR>/kits/paidcommunity" \
  -pkgdir ./gno/r/gnoforge/kits/paidcommunity \
  -gas-fee 1000000ugnot -gas-wanted 50000000 \
  -chainid staging -remote https://rpc.staging.gno.land:443 \
  <KEY>
```

> Pure packages `roles` and `membership` must be deployed first (or use already-published paths).
