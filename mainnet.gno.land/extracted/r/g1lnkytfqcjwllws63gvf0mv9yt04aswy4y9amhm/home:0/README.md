# home

The realm behind the profile page at `/u/<namespace>`. gnoweb calls
`Render("")` on the realm at exactly `/r/<namespace>/home`, so this path is
permanent and everything that may change lives behind it:

- **Content** is slots: named markdown fragments, one `Set` transaction each.
- **Layout** is the slot named `layout`, a template filled from `:slug:`
  placeholders.
- **Style** is slots under `style.` that the theme reads.
- **Rendering** is a theme: a realm under `home/theme/vN` that registers itself
  when deployed and goes live when the authority runs `Accept`. `Rollback`
  reverts. The slots never move.

The upgrade machinery is `p/<namespace>/upgradeable/v0`.

## Views

| path | what |
| --- | --- |
| `:slots` | slot index |
| `:slots/<slug>` | one slot, raw |
| `:edit`, `:edit/<slug>` | forms that build the `Set` and `Delete` commands |
| `:system` | authority, live theme, candidates, history, operations |
| `:manifest` | `slug⇥rev⇥bytes⇥sha256` per slot, for tooling |

These four are served by this realm directly and never go through a theme, so
a theme that panics can be rolled back from `:system`. Every other path is the
theme's.

## Writes

Restricted to the authority: `Set`, `Append`, `Delete`; `Accept`, `Withdraw`,
`Rollback`, `Forget`, `Freeze`, `TransferAuthority`. A slug is 1 to 64 bytes
of `[a-z0-9._-]`; the computed placeholders `chainid height owner realm rev
slots theme updated` are reserved.
