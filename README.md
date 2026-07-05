# TailAdjuster

**Bulk-deploy [Tailscale](https://tailscale.com) across every LXC container and VM on a Proxmox VE node — in one command.**

`tailscale-bulk-deploy.sh` scans a Proxmox host, finds every running guest, installs Tailscale where it's missing, and enrolls each one into your tailnet. It's idempotent: guests that are already connected are skipped, so you can run it as often as you like (e.g. after spinning up new containers) and it only touches what needs touching.

---

## Features

- **Covers both LXC containers and QEMU/KVM VMs** on the node.
- **Idempotent** — already-connected guests are detected and skipped; safe to re-run.
- **Auto-configures `/dev/net/tun`** for containers (adds the cgroup allow + bind mount to the container config and reboots once when needed).
- **Loads the `tun` kernel module on the host** and persists it across reboots — the single most common reason Tailscale silently fails inside containers.
- **Multi-distro guest support** — installs prerequisites via `apt`, `apk`, `dnf`, or `yum`.
- **Automatic retry** — if the first join fails (a known `tailscaled` startup race), the guest is rebooted and the join is retried once.
- **Resilient scan** — a failure on one guest never aborts the rest of the run.
- **Full run log** written to `/root/tailscale-bulk-<timestamp>.log`, plus a success/skip/fail summary at the end.

---

## Requirements

| Where | Requirement |
|-------|-------------|
| Proxmox host | Run as **root** on a Proxmox VE node (`pvesh`, `pct`, `qm` available). |
| Proxmox host | `jq` (the script auto-installs it on Debian-based hosts). |
| You | A valid **Tailscale auth key** (`tskey-auth-…`). [Generate one here.](https://login.tailscale.com/admin/settings/keys) |
| VMs only | `qemu-guest-agent` must already be **installed and running inside the VM**. See [VMs vs. containers](#vms-vs-containers). |

---

## Quick start

```bash
# 1. Get the script onto your Proxmox node (e.g. clone or scp it), then:
chmod +x tailscale-bulk-deploy.sh

# 2. Export a Tailscale auth key
export TS_AUTHKEY='tskey-auth-xxxxxxxxxxxxxxxxxxxxxxxx'

# 3. Run it as root
./tailscale-bulk-deploy.sh
```

That's it. The script prints progress to your terminal and writes a full log to `/root/`.

> **Tip:** use a [**reusable, pre-authorized** auth key](https://tailscale.com/kb/1085/auth-keys) so you don't have to approve every guest in the admin console. Consider tagging (see `TS_EXTRA_ARGS` below) so all the machines land in an easy-to-manage group.

---

## Configuration

Everything is driven by environment variables — there are no positional arguments.

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `TS_AUTHKEY` | ✅ | — | Your Tailscale auth key (`tskey-auth-…`). |
| `TS_EXTRA_ARGS` | | _(empty)_ | Extra flags appended to every `tailscale up` call, e.g. `--ssh --accept-routes --advertise-tags=tag:prox`. |
| `TS_HOSTNAME_PREFIX` | | `ct-` / `vm-` | Override the hostname prefix used at enrollment. By default containers enroll as `ct-<id>` and VMs as `vm-<id>`; set this to force a single prefix for both. |
| `TS_LOGIN_SERVER` | | _(Tailscale)_ | Point at a custom control server (e.g. [Headscale](https://github.com/juanfont/headscale)). Passed as `--login-server=<url>`. |
| `PVE_NODE` | | `$(hostname -s)` | Node name to scan. Override if the short hostname doesn't match your PVE node name. |

### Examples

Enroll everything with Tailscale SSH enabled and a tag:

```bash
export TS_AUTHKEY='tskey-auth-…'
export TS_EXTRA_ARGS='--ssh --advertise-tags=tag:proxmox'
./tailscale-bulk-deploy.sh
```

Point at a self-hosted Headscale control server:

```bash
export TS_AUTHKEY='…'
export TS_LOGIN_SERVER='https://headscale.example.com'
./tailscale-bulk-deploy.sh
```

Show the built-in help:

```bash
./tailscale-bulk-deploy.sh --help
```

---

## What it does, step by step

1. **Preflight** — verifies it's running as root on a Proxmox node, that `TS_AUTHKEY` is set, ensures `jq` is present, and loads/persists the `tun` kernel module on the host.
2. **Scan LXC containers** (`pvesh get /nodes/<node>/lxc`). For each *running* container:
   - Skip if Tailscale is already up and has a `100.x` address.
   - Ensure `/dev/net/tun` is exposed to the container (edit config + reboot once if it wasn't).
   - Install Tailscale if missing.
   - `tailscale up` with your auth key, enrolling as `ct-<id>`.
   - On failure: reboot the container and retry once, dumping the last 15 `tailscaled` journal lines if it still fails.
3. **Scan VMs** (`pvesh get /nodes/<node>/qemu`). For each *running* VM with a **responding guest agent**:
   - Same install → join → retry flow, executed inside the guest via the QEMU guest agent, enrolling as `vm-<id>`.
4. **Summary** — prints `Success / Skipped / Failed` counts and the log path.

---

## VMs vs. containers

**Containers (LXC)** are fully automatic. The Proxmox host can run commands directly inside a container with `pct exec`, so the script can install Tailscale, tweak the container config for `/dev/net/tun`, reboot, and join — all unattended.

**VMs** are different. There is **no way to run a command inside a VM's OS from the host** unless the [QEMU guest agent](https://pve.proxmox.com/wiki/Qemu-guest-agent) is installed and running *inside* the guest. The script cannot bootstrap the agent remotely — that's a chicken-and-egg problem. So:

- VMs **with** a responding guest agent are handled automatically, just like containers.
- VMs **without** one are **skipped** with a message telling you to install `qemu-guest-agent` once (via console or SSH). After that, re-run the script and it will pick them up.

To enable the agent on a Debian/Ubuntu VM:

```bash
# inside the VM
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

…and make sure the QEMU Guest Agent option is enabled for the VM in Proxmox (**VM → Options → QEMU Guest Agent**), then reboot the VM once.

---

## Notes, caveats & troubleshooting

- **Unprivileged containers.** TUN bind-mounts frequently fail at runtime for unprivileged containers that lack a matching `lxc.idmap`. The script proceeds and warns you — **verify these manually** afterward. If a join fails on an unprivileged CT, that's the first thing to check.
- **The `tun` module is host-wide.** If `tailscaled` runs but has "no control socket" or can't create the interface inside a guest, it's almost always because `/dev/net/tun` on the *host* wasn't backed by a loaded module. The script fixes this on the host up front.
- **`--reset` is used on join.** Each fresh enroll runs `tailscale up --reset …`, which clears any previous, non-default `tailscale up` settings on that guest. This keeps enrollment deterministic; if you rely on per-guest flags, bake them into `TS_EXTRA_ARGS`.
- **Auth key visibility.** The key is passed to `tailscale up` inside each guest. Prefer short-lived / reusable keys and rotate them after a bulk run. The key is **not** written to the log file.
- **Logs.** Every run is teed to `/root/tailscale-bulk-<timestamp>.log`. Failed joins include the last 15 lines of the guest's `tailscaled` journal to speed up diagnosis.
- **Nothing happens / everything skipped.** That's the expected result on a second run — every guest is already in the tailnet. 🎉

---

## Safety

This script modifies guest configurations (container `.conf` files), reboots guests when required, and installs software inside them. It's designed to be safe and idempotent, but you are running it against your whole node — **read it first** (it's a single, well-commented Bash file) and consider trying it on a single test guest before a full sweep.

---

## License

Licensed under the [Apache License 2.0](LICENSE).
