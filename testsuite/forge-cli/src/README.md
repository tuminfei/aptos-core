---
id: forge cli
title: Forge CLI
custom_edit_url: https://github.com/aptos-labs/aptos-core/edit/main/testsuite/forge-cli/README.md
---

# Forge CLI

This crate contains the Forge command line interface (CLI) tool. This enables users to
run local and remote Aptos swarms (i.e., networks of validators and validator fullnodes). For
example, to deploy a local validator swarm, run:

```
cargo run -p aptos-forge-cli -- --suite "run_forever" --num-validators 4 test local-swarm
```

This will start a local network of 4 validators, each running in their own process. The
network will run forever, unless manually killed. The output will display the locations
of the validator files (e.g., the genesis files, logs, node configurations, etc.) and the
commands that were run to start each node. The process id (PID) of each node and
server addresses (e.g., REST APIs) are also displayed when it starts. For example, if you
run the above command you should see:

```
...
2022-09-01T15:41:27.228289Z [main] INFO crates/aptos-genesis/src/builder.rs:462 Building genesis with 4 validators. Directory of output: "/private/var/folders/dx/c0l2rrkn0656gfx6v5_dy_p80000gn/T/.tmpq9uPMJ"
...
2022-09-01T15:41:28.090606Z [main] INFO testsuite/forge/src/backend/local/swarm.rs:207 The root (or mint) key for the swarm is: 0xf9f...
...
2022-09-01T15:41:28.094800Z [main] INFO testsuite/forge/src/backend/local/node.rs:129 Started node 0 (PID: 78939) with command: ".../aptos-core/target/debug/aptos-node" "-f" "/private/var/folders/dx/c0l2rrkn0656gfx6v5_dy_p80000gn/T/.tmpq9uPMJ/0/node.yaml"
2022-09-01T15:41:28.094825Z [main] INFO testsuite/forge/src/backend/local/node.rs:137 Node 0: REST API is listening at: http://127.0.0.1:64566
2022-09-01T15:41:28.094838Z [main] INFO testsuite/forge/src/backend/local/node.rs:142 Node 0: Inspection service is listening at http://127.0.0.1:64568
...
```

Using the information from this output, you could stop a single node and restart
it, e.g., stop and restart node `0`:

```
kill -9 <Node 0 PID>
cargo run -p aptos-node -- -f <Location to the node 0 configuration file displayed above>
```

## Generate configs for specific IPs

Pass one IPv4 address per validator in node index order. When using validator fullnodes,
pass one `--fullnode-ips` address per VFN. The first VFN is paired with validator 0,
the second with validator 1, and so on. Use `--generate-only` for nodes on separate
hosts, then copy each numbered node directory to its corresponding host.
The advertised validator and VFN addresses are written into genesis. The node configs
continue to listen on `0.0.0.0` with their assigned ports.

```bash
cargo run -p aptos-forge-cli -- --suite run_forever --num-validators 4 \
  --num-validator-fullnodes 2 \
  test local-swarm --generate-only --swarmdir /opt/aptos/swarm \
  --node-ips 10.0.0.11,10.0.0.12,10.0.0.13,10.0.0.14 \
  --fullnode-ips 10.0.0.21,10.0.0.22
```

This creates validators `0` through `3` and VFNs `4` and `5`. VFN `4` belongs to
validator `0`; VFN `5` belongs to validator `1`. Their public network identity files
are placed in the VFN directories so the directories can be copied independently.
The validators' VFN network ports must be reachable from their paired VFNs, and the
advertised validator and VFN ports must be reachable from the other nodes.

The generated YAML files contain absolute paths, so keep the same directory paths
on the target hosts or update the paths before starting `aptos-node`. For separate
hosts, supply both `--node-ips` and `--fullnode-ips`. Without `--fullnode-ips`,
each VFN advertises its validator's IP; without either option, Forge keeps its
original local addresses. `--generate-only` requires a new `--swarmdir` and
does not start any node processes. A launched local swarm removes and recreates an
existing `--swarmdir`, so do not point it at data you need to retain.
The REST API keeps its local bind address; adjust `api.address` separately if remote API
access is needed.

On each host, start its numbered validator with the matching config, for example:

```bash
aptos-node -f /opt/aptos/swarm/0/node.yaml
```
Start VFN `4` with `/opt/aptos/swarm/4/node.yaml` and VFN `5` with
`/opt/aptos/swarm/5/node.yaml` on their respective hosts.
Config generation does not build `aptos-node`. Start each node with the binary
version you intend to deploy. For a launched local swarm, pass
`--aptos-node-binary /path/to/aptos-node` to reuse an existing binary;
otherwise Forge builds one from the workspace.

For a swarm that runs on this machine, `--node-ips` and `--fullnode-ips` can
also be used without `--generate-only` if all supplied IPs route to this machine.

## Faucet and minting

In order to mint coins in this test network you need to run a faucet. You can do that with this command:

```bash
cargo run -p aptos-faucet-service -- run-simple --key <key> --node-url <node_url>
```

You can get the values above like this:
- `key`: When you started the swarm, there was output like this: `The root (or mint) key for the swarm is: 0xf9f...`. This is the `key`.
- `node_url`: When you started the swarm, there was output like this: `REST API is listening at: http://127.0.0.1:64566`. This is the `node_url`.

The above command will run a faucet locally, listening on port `8081`. Using this faucet, you can then mint tokens to your test accounts, for example:

```bash
curl -X POST http://127.0.0.1:8081/mint?amount=<amount to mint>&pub_key=<public key to mint tokens to>
```

As an alternative to using the faucet service, you may use the faucet CLI directly:
```
cargo run -p aptos-faucet-cli -- --amount 10 --accounts <account_address> --key <private_key>
```

:::tip Faucet and Aptos CLI
See more on how the faucet works in the [README](https://github.com/aptos-labs/aptos-core/tree/main/crates/aptos-faucet).

Also see how to use the [Aptos CLI](../cli-tools/aptos-cli/use-cli/use-aptos-cli.md#account-examples) with an existing faucet.
:::

## Validator fullnodes

To also run validator fullnodes inside the network, use the `--num-validator-fullnodes` flag, e.g.,:
```
cargo run -p aptos-forge-cli -- --suite "run_forever" --num-validators 3 --num-validator-fullnodes 1 test local-swarm
```

## Additional usage

To see all tool usage options, run:
```
cargo run -p aptos-forge-cli --help
```
