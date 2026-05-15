Local k3d Aptos testnet
=======================

This directory provides a lightweight local Kubernetes setup for running a 4-validator Aptos testnet on k3d.

Prerequisites
-------------

- Docker
- k3d
- kubectl
- Helm

Quick start
-----------

```bash
./docker/k3d/start_k3d.sh
```

This script will:

- create a local k3d cluster named `aptos-local`
- install a 4-validator Aptos network into namespace `aptos-local`
- run the genesis job
- wait for the validator and fullnode statefulsets to become ready

Useful commands
---------------

```bash
kubectl config use-context k3d-aptos-local
kubectl -n aptos-local get pods
kubectl -n aptos-local get svc
helm -n aptos-local list
```

Cleanup
-------

```bash
./docker/k3d/stop_k3d.sh
```

Notes
-----

- This setup intentionally uses much smaller CPU, memory, and PVC sizes than the cloud defaults.
- External services are exposed as `ClusterIP` inside the cluster to avoid cloud `LoadBalancer` dependencies.
- The local chart configuration keeps one validator fullnode group so each validator has a paired VFN.
