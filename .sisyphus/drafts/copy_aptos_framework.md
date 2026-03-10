# Draft: Copy and Modify Aptos Framework

## Requirements (confirmed)

- Copy the entire directory "aptos-move/framework" to "aptos-move/topo-framework".
- Rename modules under `0x1::` from `aptos_*` to `poto_*` within the new framework.
- Rename "Aptos Coin" to "Topo Coin" and related constants/functions within the new framework.

## Scope of Copy

- Entire `aptos-move/framework` directory.

## Renaming Strategy

- Focus renaming on:
  - Module names starting with `aptos_` under `0x1::` (rename to `poto_*`).
  - Identifiers and string literals related to "Aptos Coin" (rename to "Topo Coin").
  - Related constants and functions.
- Avoid broad search for all "aptos" patterns for now.

## Test Strategy

- Adapt and rewrite existing tests from `aptos-move/framework` to work with `topo-framework`.

## Open Questions

- None at this time. All requirements seem clear.
