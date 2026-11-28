# pager

Bounded pagination over an `avl.Tree`: the drop-in fix for Assayer rules
AS-G01 (unbounded iteration) and AS-G02 (Render walks all state).

```go
offset, limit := pager.Parse(path)          // "?page=2&size=20"
page := pager.Of(posts, offset, limit, true) // newest first, never more than MaxLimit
for _, it := range page.Items { /* … */ }
out += page.Nav("")                         // « prev | page 2/7 | next »
```

Every walk is capped at `MaxLimit` (100) entries, so the gas of a page does
not grow with the size of the tree.
