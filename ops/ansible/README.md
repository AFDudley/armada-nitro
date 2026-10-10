# Fixturenet host setup (ansible)

The armada-nitro fixturenet is stable only when its chain gets uncontended CPU
and low-latency disk. On a shared host this needs some host-level setup that the
stack itself cannot do from inside containers. This role makes that setup
reproducible on any Linux Docker host, parametrized so nothing about our
reference host (kelce) is baked in.

Read `docs/tasks/E12-lido-full-scratch.md` ("As built") for *why* each piece
exists — briefly:

- **A CPU-pinned systemd slice.** The fixturenet's six containers (geth, the
  beacon, four validators) run under a dedicated `fixturenet.slice` whose
  `AllowedCPUs` reserves a block of cores; the compose file pins each container
  to its own core(s) within that block (`cgroup_parent` + `cpuset`). Reserving
  the cores took them from 90–96 % busy to <1 % under host load, which stopped
  the chain reorging.
- **Capped tmpfs data.** Each deployment's `data/` is a size-capped tmpfs, so the
  chain's fsyncs never wait behind other writers on a shared disk (0 reorgs on
  RAM vs. 20 over 10 min on a busy pool), and a forgotten fixturenet fills its
  RAM disk and dies instead of growing without bound. A reboot empties it; a
  fresh reconcile rebuilds the chain.
- **(Opt-in) host-wide isolation.** Confine *everything else* on the host to the
  complementary cores and narrow the kernel workqueue mask, so no other workload
  can bleed onto the reserved cores. This is invasive — it touches every other
  cgroup on the machine — so it is **off by default** and must be an explicit
  choice.

## Prerequisites

- Linux with **cgroup v2** (unified hierarchy) and **systemd**.
- **Docker** using the **systemd cgroup driver** (so `cgroup_parent` can name a
  systemd slice). Set this in `/etc/docker/daemon.json` and restart docker:
  ```json
  { "exec-opts": ["native.cgroupdriver=systemd"] }
  ```
- `ansible-core` on the machine you run the playbook from, and passwordless
  `sudo` on the target (the role writes systemd units under `/etc`).
- `laconic-so` and the ability to build/run this stack (see `stack/README.md`).

The role asserts cgroup v2, the docker cgroup driver, and that your reserved
CPUs exist, before changing anything.

## Variables

Set these in an inventory/host_vars file or a `-e @vars.yml`. Only
`fixturenet_slice_allowed_cpus` is required for the core setup; the isolation
vars are required only if you turn isolation on. See
`roles/fixturenet_host/defaults/main.yml` for the full list and comments.

| Variable | Default | Meaning |
| --- | --- | --- |
| `fixturenet_slice_name` | `fixturenet.slice` | Slice the containers run under. Must match the compose `FIXTURENET_SLICE` config var. |
| `fixturenet_slice_allowed_cpus` | *(required)* | `AllowedCPUs` list for the slice, e.g. `10-15,26-31`. |
| `fixturenet_tmpfs_mounts` | `[]` | List of `{path, size?, mode?}` — a capped tmpfs per deployment `data/` dir, root-only (mode `0700`) by default: host code reaches deployment state through `run-job` and RPC, not these files. |
| `fixturenet_tmpfs_default_size` | `3G` | Default tmpfs size. |
| `fixturenet_host_isolation` | `false` | Opt-in host-wide isolation (below). |
| `fixturenet_host_other_cpus` | `""` | `AllowedCPUs` for `system.slice`/`user.slice`/`init.scope` — the complement of the reserved cores. Required when isolation is on. |
| `fixturenet_workqueue_cpumask` | `""` | Hex mask for `/sys/devices/virtual/workqueue/cpumask`, matching `fixturenet_host_other_cpus`. Required when isolation is on. |

### How to pick CPUs

1. Count your logical CPUs (`nproc`). On an SMT/hyperthreaded host each physical
   core shows up as **two** logical CPUs; find the sibling pairs with
   `lscpu --extended` or
   `cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list | sort -u`.
   On kelce the sibling of CPU *n* is CPU *n+16* (32 CPUs, 16 physical cores).
2. Choose a contiguous block of physical cores that no other workload needs.
   You need at least **six** cores' worth of logical CPUs (geth and the beacon
   take 2 each in the compose file, one validator per remaining core). On kelce:
   physical cores 10–15 → logical CPUs `10-15` plus siblings `26-31` →
   `fixturenet_slice_allowed_cpus: "10-15,26-31"`.
3. If enabling isolation, `fixturenet_host_other_cpus` is everything else
   (`0-9,16-25` on kelce), and `fixturenet_workqueue_cpumask` is the same set as
   a hex CPU mask (little-endian 32-bit words, high word first, no `0x`).
   Compute it from the CPU list, e.g.:
   ```sh
   python3 - <<'PY'
   cpus = []
   for part in "0-9,16-25".split(","):
       a, b = (part.split("-") + [part])[:2]
       cpus += range(int(a), int(b) + 1)
   mask = 0
   for c in cpus:
       mask |= 1 << c
   words = []
   while mask or not words:
       words.append(f"{mask & 0xffffffff:08x}")
       mask >>= 32
   print(",".join(reversed(words)))   # 0-9,16-25 -> 03ff03ff
   PY
   ```
   For `0-9,16-25` the single 32-bit word is bits 0–9 (`0x03ff`) plus bits 16–25
   (`0x03ff` shifted) → `03ff03ff`.

The slice `AllowedCPUs` and the compose per-service `cpuset`s must be consistent:
every `cpuset` CPU must be inside `fixturenet_slice_allowed_cpus`.

## Run the playbook

From this directory (`ops/ansible/`):

```sh
# Copy the example vars and edit for your host, or pass kelce's as-is:
ansible-playbook -i inventory.example.ini site.yml -e @examples/kelce.yml

# Dry run (check mode) first if you like:
ansible-playbook -i inventory.example.ini site.yml -e @examples/kelce.yml --check

# Only part of it:
ansible-playbook -i inventory.example.ini site.yml -e @examples/kelce.yml --tags slice
#   tags: preflight, slice, isolation, tmpfs
```

`examples/kelce.yml` reproduces this repo's reference host exactly (slice
`10-15,26-31`, isolation on with the rest on `0-9,16-25`, a 3G tmpfs for the E12
deployment). Second run reports `changed=0`.

## Bring up the fixturenet with the slice, cpusets and tmpfs

The compose file reads the slice name and per-service cpusets from deployment
config variables (`FIXTURENET_SLICE`, `GETH_CPUSET`, `BEACON_CPUSET`,
`VALIDATOR_0_CPUSET`…`VALIDATOR_3_CPUSET`), each with the kelce values as
defaults. laconic-so writes them into the deployment's `config.env` and passes
that as docker compose's `--env-file`, so they drive `cgroup_parent`/`cpuset`.

> **Pass them with `--config-file`, not `--config`.** `--config` splits its
> argument on commas, and cpuset values like `10,26` contain commas.
> `examples/deployment-config.example.env` is a ready-to-use file (edit the
> cpusets to match your reserved cores, and set your own `DEPLOYER_KEY`).

Ordering matters for the tmpfs: it must go on **after** `deploy create` (which
creates `data/` and the per-volume subdirectories) and **before** `... start`.
Point `fixturenet_tmpfs_mounts[].path` at this deployment's `data/` dir and run
the playbook between the two:

```sh
DEP=~/deployments/armada-fixturenet-e12

# 1. Build the images once (see stack/README.md).
laconic-so --stack stack/stacks/armada-nitro-fixturenet build-containers

# 2. Init the spec with the cpuset/slice config vars + the deployer key.
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy init \
  --map-ports-to-host localhost-same \
  --config-file ops/ansible/examples/deployment-config.example.env \
  --output $DEP-spec.yml

# 3. Create the deployment dir (makes $DEP/data and the empty volume subdirs).
laconic-so --stack stack/stacks/armada-nitro-fixturenet deploy create \
  --spec-file $DEP-spec.yml --deployment-dir $DEP

# 4. Apply the host setup, incl. the tmpfs over $DEP/data
#    (fixturenet_tmpfs_mounts[].path == $DEP/data).
ansible-playbook -i inventory.example.ini site.yml -e @examples/kelce.yml

# 5. Start; docker recreates the volume dirs inside the RAM disk.
laconic-so deployment --dir $DEP start

# 6. Reconcile the environment and run the gates (see stack/README.md).
laconic-so deployment --dir $DEP run-job armada-env-reconcile
laconic-so deployment --dir $DEP run-job armada-env-verify
laconic-so deployment --dir $DEP run-job armada-nitro-e2e
```

The first `armada-env-reconcile` does a full deploy and takes ~25 min on the
reference host. Run it in the foreground and wait, or, for an unattended run
that survives a dropped SSH session or a tool-call timeout, detach it and follow
its log (the reconcile job sets `PYTHONUNBUFFERED=1`, so `docker logs` / the
journal stream progress live):

```sh
sudo systemd-run --collect --unit=armada-reconcile \
  -p User=$USER -p WorkingDirectory=$DEP -E HOME=$HOME -E PATH=$PATH \
  ~/bin/laconic-so deployment --dir $DEP run-job armada-env-reconcile
sudo journalctl -u armada-reconcile -f          # follow
systemctl status armada-reconcile               # exit code when done
```

(`systemd-run --user` would avoid `sudo`, but needs a systemd user session bus, which an SSH login
often lacks: it fails with "Failed to connect to bus".)

A second `armada-env-reconcile` sends no transactions and reports every module
`present, 0`.

Replacing an existing deployment first? Tear it down before recreating, since
`deploy create` refuses an existing directory and the tmpfs must be unmounted to
remove it:

```sh
laconic-so deployment --dir $DEP stop --delete-volumes
sudo systemctl stop "$(systemd-escape -p --suffix=mount $DEP/data)"
rm -rf $DEP $DEP-spec.yml
```

## Verify the intended state

```sh
systemctl show fixturenet.slice system.slice user.slice init.scope -p AllowedCPUs
cat /sys/devices/virtual/workqueue/cpumask          # isolation only
findmnt ~/deployments/armada-fixturenet-e12/data
docker inspect -f '{{.Name}} {{.HostConfig.CgroupParent}} {{.HostConfig.CpusetCpus}}' \
  $(docker ps -q --filter name=armada-fixturenet)
```
