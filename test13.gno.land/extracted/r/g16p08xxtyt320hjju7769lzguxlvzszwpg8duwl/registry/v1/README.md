# GnoForge Registry

On-chain kit catalog.

## Bootstrap

1. Deploy pure package `roles/v0`
2. Deploy this realm
3. Call `InitRegistry`
4. Call `RegisterKit` for each kit

## RegisterKit args

`id, name, version, pkgpath, category, description, tags, license`
