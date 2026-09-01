# The Aptos Framework Book

This is the reference documentation for the on-chain Move modules that
ship with the Aptos blockchain. The contents are generated directly from
the framework source.

For the Move *language* — syntax, semantics, idioms, the prover — see the
companion **[Move on Aptos Book](https://aptos-labs.github.io/move-book/)**.

## Framework packages

The book covers six packages, organised by part in the sidebar. Each
package has its own overview page (linked below) that lists every module
in the package; the modules themselves are individual chapters.

| Package                                                              | Address | What it contains                                                                                                                  |
| -------------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| [Move Standard Library](move-stdlib/overview.md)                     | `0x1`   | Core primitives shared with every Move-based chain: `vector`, `option`, `signer`, `string`, `error`, `bcs`, `hash`.               |
| [Aptos Standard Library](topo-stdlib/overview.md)                   | `0x1`   | Aptos-specific data structures and cryptography built on top of `move-stdlib`: `big_vector`, `simple_map`, `bls12381`, `ed25519`. |
| [Aptos Framework](topo-framework/overview.md)                       | `0x1`   | Core chain modules: accounts, coins, fungible assets, governance, staking, blocks, timestamps, code publishing.                   |
| [Aptos Token Objects](topo-token-objects/overview.md)               | `0x4`   | Token framework built on the Aptos object model: collections, tokens, properties, royalties.                                      |
| [Aptos Trading Framework](topo-trading/overview.md)                 | `0x5`   | On-chain order books and market-data primitives.                                                                                  |
| [Aptos Experimental Framework](aptos-experimental/overview.md)       | `0x7`   | In-development modules being incubated for future inclusion in the core framework.                                                |

The sidebar (left) is the full table of contents; the part headings group
modules by package.

## Other references

- **[Move on Aptos Book](https://aptos-labs.github.io/move-book/)** —
  the language guide, including the Move Prover and the Aptos CLI.
- **[Aptos developer docs](https://aptos.dev/)** — getting started,
  tutorials, tooling, and ecosystem.
- **[aptos-core on GitHub](https://github.com/aptos-labs/aptos-core)** —
  source code for the framework, the Move toolchain, and the node.
