# million

Realm `gno.land/r/g19t6f4f4ptt3m949jznalfsx2h8aj696llul0nj/million/v0`: a 1250 x 800 (one million pixels, 16:10) pay-per-pixel canvas
built on `gno.land/p/g19t6f4f4ptt3m949jznalfsx2h8aj696llul0nj/canvas/v0`.

Paint from the CLI:

```sh
gnokey maketx call -pkgpath gno.land/r/g19t6f4f4ptt3m949jznalfsx2h8aj696llul0nj/million/v0 -func PaintBatch \
  -args "10,10,6;11,10,6" -send 100000ugnot \
  -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid dev -remote 127.0.0.1:26657 <key>
```

The amount sent must equal `Price()` times the number of pixels, and the
call must come directly from a user transaction. Payments are forwarded to
the admin wallet (`Owner()`) as they arrive; the admin paints for free and
can `SetPrice`, `SetMaxBatch`, `Withdraw` and `TransferOwnership` (all params are owner-settable at runtime). Read functions used by clients:
`GetWidth`, `GetHeight`, `Price`, `Palette`, `MaxBatchSize`, `Painted`,
`Pixel(x, y)`, `Rows(from, to)`, `Version()`, `DirtyRows(since)`.

`Version()` counts successful paint calls and `DirtyRows(since)` lists the
rows touched after that version, so clients fetch only what changed.
