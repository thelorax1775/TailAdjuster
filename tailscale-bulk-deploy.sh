#!/usr/bin/env bash
#
# Proxmox Bulk Tailscale Deployment
# Scans all LXC containers and VMs, installs Tailscale where missing,
# and joins them to the tailnet if they aren't already connected.
#
# REQUIREMENTS:
#   - Run as root on a Proxmox VE node.
#   - jq must be installed on the host (used to parse pvesh/qm JSON output).
#     The script will attempt to install it automatically on Debian-based hosts.
#   - TS_AUTHKEY env var must be set to a valid Tailscale auth key.
#   - For VMs: qemu-guest-agent must already be installed and running
#     *inside* the VM. There is no way to run commands inside a VM's OS
#     from the Proxmox host otherwise — this script can't bootstrap the
#     agent remotely. VMs without a responding agent are skipped with a
#     message telling you to install it manually (console/SSH) once;
#     after that this script will pick them up on future runs.
#
# USAGE:
#   export TS_AUTHKEY='tskey-auth-xxxxxxxxxxxx'
#   ./tailscale-bulk-deploy.sh
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   TS_EXTRA_ARGS        Extra flags appended to every `tailscale up` call,
#                        e.g. "--ssh --accept-routes --advertise-tags=tag:prox".
#   TS_HOSTNAME_PREFIX   Override the hostname prefix used when enrolling.
#                        Defaults to "ct-" for containers and "vm-" for VMs;
#                        set this to use a single custom prefix for both.
#   TS_LOGIN_SERVER      Point at a custom control server (Headscale, etc).
#                        Appended as `--login-server=<url>`.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    # Print the leading comment block (everything between the shebang and the
    # first blank/`set` line), stripping the leading "# ".
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LOG="/root/tailscale-bulk-$(date +%F_%H-%M-%S).log"
AUTH_KEY="${TS_AUTHKEY:-}"
NODE="${PVE_NODE:-$(hostname -s)}"
EXTRA_ARGS="${TS_EXTRA_ARGS:-}"
HOSTNAME_PREFIX="${TS_HOSTNAME_PREFIX:-}"

# Assemble any always-on extra flags (login server, user-supplied extras).
if [[ -n "${TS_LOGIN_SERVER:-}" ]]; then
    EXTRA_ARGS="--login-server=${TS_LOGIN_SERVER} ${EXTRA_ARGS}"
fi

SUCCESS=0
FAILED=0
SKIPPED=0

exec > >(tee -a "$LOG") 2>&1

# shellcheck disable=SC2154  # $s is assigned within the trap body itself
trap 's=$?; echo "[X] Unexpected error near line $LINENO (exit $s)" >&2' ERR

echo "======================================="
echo " Proxmox Bulk Tailscale Deployment"
echo "======================================="
echo "Log:  $LOG"
echo "Node: $NODE"
echo

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[X] This script must be run as root on a Proxmox VE node."
    exit 1
fi

if ! command -v pvesh >/dev/null 2>&1; then
    echo "[X] pvesh not found. This does not look like a Proxmox VE node."
    exit 1
fi

if [[ -z "$AUTH_KEY" ]]; then
    echo "[X] TS_AUTHKEY is not set. Export a valid Tailscale auth key first:"
    echo "    export TS_AUTHKEY='tskey-auth-...'"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[*] jq not found, installing..."
    { apt update -y && apt install -y jq; } >/dev/null 2>&1 || true
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[X] jq is required and could not be installed. Aborting."
    exit 1
fi

# The most common cause of "tailscaled running but socket missing" is that
# the tun kernel module was never loaded on the Proxmox HOST, so there's
# nothing valid for any container's bind mount to point at, no matter how
# many times the container itself is restarted.
if ! lsmod | grep -qw '^tun'; then
    echo "[!] tun kernel module not loaded on host — loading it now"
    modprobe tun
    echo tun > /etc/modules-load.d/tun.conf   # persist across host reboots
fi

# Safe counter increment. `((x++))` returns a *false* exit status when x is
# currently 0 (post-increment evaluates to the old value), which trips
# `set -e` the first time any counter goes from 0 to 1. This avoids that.
inc() {
    local -n _v="$1"
    _v=$(( _v + 1 ))
}

# ---------------------------------------------------------------------------
# LXC helpers
# ---------------------------------------------------------------------------

is_lxc_tailscale_active() {
    pct exec "$1" -- bash -c '
        command -v tailscale >/dev/null 2>&1 || exit 1
        tailscale status >/dev/null 2>&1 || exit 1
        tailscale status 2>/dev/null | grep -q "100\."
    ' >/dev/null 2>&1
}

lxc_is_privileged() {
    local conf="/etc/pve/lxc/$1.conf"
    ! grep -q '^unprivileged:\s*1' "$conf" 2>/dev/null
}

# Polls until a container responds to pct exec, up to timeout seconds.
wait_for_lxc_ready() {
    local ct="$1" timeout="${2:-30}" elapsed=0
    while (( elapsed < timeout )); do
        if pct exec "$ct" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done
    return 1
}

enable_tun_lxc() {
    local ct="$1"
    local conf="/etc/pve/lxc/${ct}.conf"

    if grep -q 'lxc.cgroup2.devices.allow: c 10:200 rwm' "$conf" 2>/dev/null; then
        return 1   # already configured, nothing changed
    fi

    echo "[*] Enabling /dev/net/tun for CT $ct"

    if ! lxc_is_privileged "$ct"; then
        echo "[!] CT $ct is UNPRIVILEGED. TUN bind-mounts often fail at"
        echo "    runtime for unprivileged containers without a matching"
        echo "    lxc.idmap entry. Proceeding, but verify manually afterward."
    fi

    cat >> "$conf" <<'EOF'

# Tailscale requirement
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
    return 0
}

install_tailscale_lxc() {
    local ct="$1"
    pct exec "$ct" -- bash -c '
        set -e
        if command -v tailscale >/dev/null 2>&1; then
            echo "[+] Tailscale already installed"
            exit 0
        fi
        echo "[*] Installing dependencies..."
        if command -v apt >/dev/null 2>&1; then
            apt update -y >/dev/null 2>&1
            apt install -y curl ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl ca-certificates >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl ca-certificates >/dev/null 2>&1
        else
            echo "[X] No supported package manager found" >&2
            exit 1
        fi
        echo "[*] Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    '
}

join_tailnet_lxc() {
    local ct="$1"
    local hostname="${HOSTNAME_PREFIX:-ct-}$ct"

    if is_lxc_tailscale_active "$ct"; then
        echo "[SKIP] Already in tailnet"
        return 0
    fi

    # tailscale can be installed but tailscaled not actually running
    # (seen on CTs where it was installed in an earlier pass and the
    # service never came up). Make sure it's running before trying to join.
    pct exec "$ct" -- bash -c 'systemctl enable --now tailscaled >/dev/null 2>&1' || true

    echo "[*] Joining tailnet (fresh enroll) as '$hostname'"

    if pct exec "$ct" -- bash -c "
        set -e
        tailscale up --reset --authkey '$AUTH_KEY' --hostname '$hostname' $EXTRA_ARGS
    "; then
        echo "[+] Joined tailnet"
        return 0
    else
        echo "[X] Tailnet join failed"
        echo "    --- tailscaled journal (last 15 lines) ---"
        pct exec "$ct" -- journalctl -u tailscaled -n 15 --no-pager 2>/dev/null | sed 's/^/    /' || true
        echo "    -------------------------------------------"
        return 1
    fi
}

process_lxc() {
    local ct="$1" name="$2"

    echo "---------------------------------------"
    echo "LXC $ct | $name"
    echo "---------------------------------------"

    if is_lxc_tailscale_active "$ct"; then
        echo "[SKIP] Tailscale already active in tailnet"
        inc SKIPPED
        return
    fi

    local modified=0
    if enable_tun_lxc "$ct"; then
        modified=1
    fi

    if ! install_tailscale_lxc "$ct"; then
        echo "[X] Install failed"
        inc FAILED
        return
    fi

    if [[ $modified -eq 1 ]]; then
        echo "[*] Restarting CT $ct for TUN changes"
        # NOTE: `pct restart` does not exist — pct's subcommands are
        # reboot/stop/start/shutdown, not restart. Using the wrong one
        # here previously crashed the whole script under set -e and
        # silently skipped every container after the failure point.
        if ! pct reboot "$ct"; then
            echo "[X] Restart failed for CT $ct"
            inc FAILED
            return
        fi
        wait_for_lxc_ready "$ct" 30 || true
        sleep 5
    fi

    if join_tailnet_lxc "$ct"; then
        inc SUCCESS
        echo
        return
    fi

    # First join attempt failed. This is the same symptom seen with
    # sonarr/radarr: tailscaled reports "not running", or shows a live pid
    # with no control socket. A full container reboot reliably clears it,
    # so retry once automatically before giving up.
    echo "[*] Join failed — rebooting CT $ct and retrying once"
    if ! pct reboot "$ct"; then
        echo "[X] Reboot failed for CT $ct"
        inc FAILED
        return
    fi

    if ! wait_for_lxc_ready "$ct" 30; then
        echo "[X] CT $ct did not come back up in time after reboot"
        inc FAILED
        return
    fi
    sleep 5   # give tailscaled a moment to fully start after boot

    if join_tailnet_lxc "$ct"; then
        echo "[+] Joined tailnet after reboot"
        inc SUCCESS
    else
        echo "[X] Still failed after reboot — needs manual investigation"
        inc FAILED
    fi
    echo
}

# ---------------------------------------------------------------------------
# VM helpers (require qemu-guest-agent already installed in the guest)
# ---------------------------------------------------------------------------

vm_agent_ready() {
    qm guest cmd "$1" ping >/dev/null 2>&1
}

# Polls until the guest agent responds again, up to timeout seconds.
# VMs take longer to boot than LXCs, so this defaults to a longer window.
wait_for_vm_agent() {
    local vmid="$1" timeout="${2:-90}" elapsed=0
    while (( elapsed < timeout )); do
        if vm_agent_ready "$vmid"; then
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    return 1
}

# Runs a bash command inside the VM guest via the QEMU agent.
# Returns success/failure based on the guest's exit code. If print_output
# is "print", also echoes the guest's stdout (used for diagnostics).
vm_guest_exec() {
    local vmid="$1" cmd="$2" print_output="${3:-}"
    local json exitcode outdata

    json=$(qm guest exec "$vmid" --timeout 60 -- bash -c "$cmd" 2>/dev/null) || return 1
    exitcode=$(echo "$json" | jq -r '.exitcode // 1')

    if [[ "$print_output" == "print" ]]; then
        outdata=$(echo "$json" | jq -r '."out-data" // ""')
        [[ -n "$outdata" ]] && echo "$outdata"
    fi

    [[ "$exitcode" == "0" ]]
}

is_vm_tailscale_active() {
    vm_guest_exec "$1" '
        command -v tailscale >/dev/null 2>&1 || exit 1
        tailscale status >/dev/null 2>&1 || exit 1
        tailscale status 2>/dev/null | grep -q "100\."
    '
}

install_tailscale_vm() {
    local vmid="$1"
    vm_guest_exec "$vmid" '
        set -e
        command -v tailscale >/dev/null 2>&1 && exit 0
        if command -v apt >/dev/null 2>&1; then
            apt update -y >/dev/null 2>&1
            apt install -y curl ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl ca-certificates >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl ca-certificates >/dev/null 2>&1
        fi
        curl -fsSL https://tailscale.com/install.sh | sh
    '
}

join_tailnet_vm() {
    local vmid="$1"
    local hostname="${HOSTNAME_PREFIX:-vm-}$vmid"

    if is_vm_tailscale_active "$vmid"; then
        echo "[SKIP] Already in tailnet"
        return 0
    fi

    # Make sure tailscaled is actually running before trying to join —
    # same failure mode as LXCs where the service never came up after install.
    vm_guest_exec "$vmid" 'systemctl enable --now tailscaled >/dev/null 2>&1' || true

    echo "[*] Joining tailnet (fresh enroll) as '$hostname'"

    if vm_guest_exec "$vmid" "tailscale up --reset --authkey '$AUTH_KEY' --hostname '$hostname' $EXTRA_ARGS"; then
        echo "[+] Joined tailnet"
        return 0
    else
        echo "[X] Tailnet join failed"
        echo "    --- tailscaled journal (last 15 lines) ---"
        vm_guest_exec "$vmid" 'journalctl -u tailscaled -n 15 --no-pager' print | sed 's/^/    /' || true
        echo "    -------------------------------------------"
        return 1
    fi
}

process_vm() {
    local vmid="$1" name="$2"

    echo "---------------------------------------"
    echo "VM $vmid | $name"
    echo "---------------------------------------"

    if ! vm_agent_ready "$vmid"; then
        echo "[SKIP] QEMU guest agent not responding."
        echo "       Install/enable qemu-guest-agent inside this VM first"
        echo "       (console or SSH), then re-run this script."
        inc SKIPPED
        return
    fi

    if is_vm_tailscale_active "$vmid"; then
        echo "[SKIP] Tailscale already active in tailnet"
        inc SKIPPED
        return
    fi

    if ! install_tailscale_vm "$vmid"; then
        echo "[X] Install failed"
        inc FAILED
        return
    fi

    if join_tailnet_vm "$vmid"; then
        inc SUCCESS
        echo
        return
    fi

    # First join attempt failed — reboot the VM and retry once, same as
    # the LXC path. Requires waiting for the guest agent to come back up
    # before anything can be run inside the guest again.
    echo "[*] Join failed — rebooting VM $vmid and retrying once"
    if ! qm reboot "$vmid"; then
        echo "[X] Reboot failed for VM $vmid"
        inc FAILED
        return
    fi

    if ! wait_for_vm_agent "$vmid" 90; then
        echo "[X] Guest agent did not come back after reboot for VM $vmid"
        inc FAILED
        return
    fi
    sleep 5   # give tailscaled a moment to fully start after boot

    if join_tailnet_vm "$vmid"; then
        echo "[+] Joined tailnet after reboot"
        inc SUCCESS
    else
        echo "[X] Still failed after reboot — needs manual investigation"
        inc FAILED
    fi
    echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "[*] Scanning LXC containers on node '$NODE'..."
while IFS=$'\t' read -r CT STATUS NAME; do
    if [[ "$STATUS" != "running" ]]; then
        echo "[SKIP] CT $CT ($NAME) not running"
        inc SKIPPED
        continue
    fi
    # `|| true` here is deliberate: a bug or unexpected failure inside
    # process_lxc should never be allowed to kill the whole scan again
    # (a single bad container previously aborted the entire run under set -e).
    process_lxc "$CT" "$NAME" || echo "[X] Unexpected failure processing CT $CT — continuing with next container"
done < <(pvesh get "/nodes/$NODE/lxc" --output-format json | jq -r '.[] | [.vmid, .status, .name] | @tsv')

echo
echo "[*] Scanning VMs on node '$NODE'..."
while IFS=$'\t' read -r VMID STATUS NAME; do
    if [[ "$STATUS" != "running" ]]; then
        echo "[SKIP] VM $VMID ($NAME) not running"
        inc SKIPPED
        continue
    fi
    process_vm "$VMID" "$NAME" || echo "[X] Unexpected failure processing VM $VMID — continuing with next VM"
done < <(pvesh get "/nodes/$NODE/qemu" --output-format json | jq -r '.[] | [.vmid, .status, .name] | @tsv')

echo
echo "======================================="
echo " DONE"
echo "======================================="
echo "Success : $SUCCESS"
echo "Skipped : $SKIPPED"
echo "Failed  : $FAILED"
echo "Log     : $LOG"
