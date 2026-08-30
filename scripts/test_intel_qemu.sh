#!/usr/bin/env bash
# Run HyperEnclave's Intel late-launch path in the prepared Ubuntu 22.04 VM.

set -Eeuo pipefail

readonly MODE="${1:-run}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

readonly HE_ELF="${HE_ELF:-$REPO_ROOT/target/x86_64/release/rust-hypervisor}"
readonly HE_DRIVER_DIR="${HE_DRIVER_DIR:-$REPO_ROOT/../hyperenclave-driver}"
readonly HE_VM_DIR="${HE_VM_DIR:-$REPO_ROOT/../hyperenclave-vm}"
readonly HE_VM_IMAGE="${HE_VM_IMAGE:-$HE_VM_DIR/hyperenclave-intel-jammy.qcow2}"
readonly HE_VM_SEED="${HE_VM_SEED:-$HE_VM_DIR/hyperenclave-intel-seed.img}"
readonly HE_SSH_KEY="${HE_SSH_KEY:-$REPO_ROOT/.hevm-key}"
readonly HE_KNOWN_HOSTS="${HE_KNOWN_HOSTS:-$HE_VM_DIR/known_hosts}"
readonly HE_SSH_HOST="${HE_SSH_HOST:-127.0.0.1}"
readonly HE_SSH_PORT="${HE_SSH_PORT:-2222}"
readonly HE_SSH_USER="${HE_SSH_USER:-ubuntu}"
readonly HE_CPUS="${HE_CPUS:-4}"
readonly HE_MEMORY="${HE_MEMORY:-8G}"
readonly HE_BOOT_TIMEOUT="${HE_BOOT_TIMEOUT:-180}"
readonly HE_ENABLE_TIMEOUT="${HE_ENABLE_TIMEOUT:-180}"
readonly HE_MEMMAP_START="${HE_MEMMAP_START:-0x100000000}"
readonly HE_MEMMAP_SIZE="${HE_MEMMAP_SIZE:-4G}"
readonly HE_FEATURE_MASK="${HE_FEATURE_MASK:-0x302}"
readonly HE_KEEP_VM_ON_FAIL="${HE_KEEP_VM_ON_FAIL:-0}"
readonly LOCK_FILE="$HE_VM_DIR/.intel-qemu-test.lock"

RUN_ID=""
RUN_DIR=""
RUN_DISK=""
SERIAL_LOG=""
DMESG_LOG=""
RUN_DMESG_LOG=""
QMP_SOCKET=""
PID_FILE=""
QEMU_PID=""

log() {
    printf '[intel-qemu] %s\n' "$*"
}

die() {
    log "ERROR: $*" >&2
    return 1
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

qemu_pid_matches() {
    local pid="$1"
    local expected_disk="$2"
    local exe cmdline

    is_uint "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$(basename "$exe")" == qemu-system-x86_64* ]] || return 1
    [[ "$cmdline" == *"$expected_disk"* ]]
}

stop_pidfile() {
    local pid_file="$1"
    local run_dir expected_disk pid attempt

    [[ -f "$pid_file" ]] || return 0
    run_dir="$(dirname "$pid_file")"
    expected_disk="$run_dir/root.qcow2"
    pid="$(<"$pid_file")"

    if ! is_uint "$pid" || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    if ! qemu_pid_matches "$pid" "$expected_disk"; then
        die "refusing to stop PID $pid: it is not the expected Intel test VM"
        return 1
    fi

    log "stopping previous Intel test VM (PID $pid)"
    kill -TERM "$pid"
    for attempt in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done

    log "QEMU did not exit after SIGTERM; stopping the validated test process"
    kill -KILL "$pid"
}

stop_existing_test_vms() {
    local pid_file
    shopt -s nullglob
    for pid_file in "$HE_VM_DIR"/.intel-qemu-test.*/qemu.pid; do
        stop_pidfile "$pid_file"
    done
    shopt -u nullglob
}

cleanup_on_exit() {
    local rc=$?
    set +e
    if ((rc != 0)) && [[ "$MODE" == run ]]; then
        log "test failed; artifacts are preserved in ${RUN_DIR:-<not-created>}" >&2
        if [[ -f "${SERIAL_LOG:-}" ]]; then
            log "last serial messages:" >&2
            tail -n 100 "$SERIAL_LOG" >&2
        fi
        if [[ "$HE_KEEP_VM_ON_FAIL" != 1 && -n "${PID_FILE:-}" ]]; then
            stop_pidfile "$PID_FILE"
        fi
    fi
    return "$rc"
}

trap cleanup_on_exit EXIT

mkdir -p "$HE_VM_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || die "another Intel/QEMU test is running (lock: $LOCK_FILE)"

if [[ "$MODE" == stop ]]; then
    stop_existing_test_vms
    log "all managed Intel test VMs are stopped"
    exit 0
fi
[[ "$MODE" == run ]] || die "usage: $0 [run|stop]"

for command in qemu-system-x86_64 qemu-img ssh scp git timeout flock ss; do
    command -v "$command" >/dev/null || die "missing host command: $command"
done
for file in "$HE_ELF" "$HE_VM_IMAGE" "$HE_VM_SEED" "$HE_SSH_KEY"; do
    [[ -r "$file" ]] || die "required file is not readable: $file"
done
[[ -d "$HE_DRIVER_DIR/.git" ]] || die "driver repository not found: $HE_DRIVER_DIR"

if [[ ! -e /dev/kvm && -r /proc/misc ]]; then
    kvm_minor="$(awk '$2 == "kvm" { print $1; exit }' /proc/misc)"
    if [[ -n "$kvm_minor" ]]; then
        log "/dev/kvm is missing; creating the WSL2 device node (sudo may prompt)"
        sudo mknod /dev/kvm c 10 "$kvm_minor"
        sudo chown "$(id -u):$(id -g)" /dev/kvm
        sudo chmod 660 /dev/kvm
    fi
fi
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || \
    die "/dev/kvm is unavailable to $(id -un); nested KVM is required (TCG is not accepted)"
grep -qw vmx /proc/cpuinfo || die "the WSL2 host does not expose Intel VMX"
qemu-system-x86_64 -accel help | grep -qw kvm || die "QEMU has no KVM accelerator"

stop_existing_test_vms
if ss -H -ltn | awk '{ print $4 }' | grep -Eq "[:.]${HE_SSH_PORT}$"; then
    die "TCP port $HE_SSH_PORT is already in use"
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$(mktemp -d "$HE_VM_DIR/.intel-qemu-test.$RUN_ID.XXXXXX")"
RUN_DISK="$RUN_DIR/root.qcow2"
SERIAL_LOG="$RUN_DIR/serial.log"
DMESG_LOG="$RUN_DIR/dmesg.log"
RUN_DMESG_LOG="$RUN_DIR/dmesg-run.log"
QMP_SOCKET="$RUN_DIR/qmp.sock"
PID_FILE="$RUN_DIR/qemu.pid"

log "creating an isolated child disk"
qemu-img create -q -f qcow2 -F qcow2 -b "$HE_VM_IMAGE" "$RUN_DISK"

log "starting Ubuntu 22.04 with nested Intel VMX/EPT"
qemu-system-x86_64 \
    -name hyperenclave-intel-it \
    -machine q35,accel=kvm,kernel-irqchip=split \
    -cpu host,kvm=off,vmx=on,vmx-ept=on,vmx-vpid=on \
    -smp "$HE_CPUS",sockets=1,cores="$HE_CPUS",threads=1 \
    -m "$HE_MEMORY" \
    -device intel-iommu,intremap=off,caching-mode=on \
    -drive "if=none,id=os,file=$RUN_DISK,format=qcow2" \
    -device virtio-blk-pci,drive=os \
    -drive "if=none,id=seed,file=$HE_VM_SEED,format=raw,readonly=on" \
    -device virtio-blk-pci,drive=seed \
    -netdev "user,id=net0,hostfwd=tcp:$HE_SSH_HOST:$HE_SSH_PORT-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -monitor none \
    -serial "file:$SERIAL_LOG" \
    -qmp "unix:$QMP_SOCKET,server=on,wait=off" \
    -no-reboot \
    -pidfile "$PID_FILE" \
    -daemonize 9>&-

QEMU_PID="$(<"$PID_FILE")"
qemu_pid_matches "$QEMU_PID" "$RUN_DISK" || die "QEMU did not start correctly"

SSH=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$HE_KNOWN_HOSTS"
    -i "$HE_SSH_KEY"
    -p "$HE_SSH_PORT"
    "$HE_SSH_USER@$HE_SSH_HOST"
)
SCP=(
    scp
    -q
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$HE_KNOWN_HOSTS"
    -i "$HE_SSH_KEY"
    -P "$HE_SSH_PORT"
)

log "waiting for SSH"
deadline=$((SECONDS + HE_BOOT_TIMEOUT))
until "${SSH[@]}" -n 'sudo -n true' >/dev/null 2>&1; do
    qemu_pid_matches "$QEMU_PID" "$RUN_DISK" || die "QEMU exited before SSH became ready"
    ((SECONDS < deadline)) || die "SSH was not ready within ${HE_BOOT_TIMEOUT}s"
    sleep 2
done
timeout --foreground 120s "${SSH[@]}" -n \
    'cloud-init status --wait >/dev/null 2>&1 || cloud-init status --long' >/dev/null

log "checking the guest kernel, reserved memory and Intel virtualization"
"${SSH[@]}" -n "set -eu; \
    kernel=\$(uname -r); \
    case \"\$kernel\" in 5.10.*) ;; *) echo \"unsupported kernel: \$kernel\" >&2; exit 1;; esac; \
    test -d \"/lib/modules/\$kernel/build\" || { echo 'guest kernel headers are missing' >&2; exit 1; }; \
    grep -F 'memmap=${HE_MEMMAP_SIZE}\$${HE_MEMMAP_START}' /proc/cmdline >/dev/null || { echo 'guest memmap is incorrect' >&2; exit 1; }; \
    grep -qw iommu=off /proc/cmdline || { echo 'guest iommu=off is missing' >&2; exit 1; }; \
    grep -qw intremap=off /proc/cmdline || { echo 'guest intremap=off is missing' >&2; exit 1; }; \
    grep -qw no5lvl /proc/cmdline || { echo 'guest no5lvl is missing' >&2; exit 1; }; \
    grep -qw vmx /proc/cpuinfo || { echo 'guest VMX is missing' >&2; exit 1; }; \
    grep -qw ept /proc/cpuinfo || { echo 'guest EPT is missing' >&2; exit 1; }; \
    grep -qw fsgsbase /proc/cpuinfo || { echo 'guest FSGSBASE is missing' >&2; exit 1; }; \
    sudo test -r /sys/firmware/acpi/tables/DMAR || { echo 'guest ACPI DMAR table is missing' >&2; exit 1; }"

guest_src="/tmp/hyperenclave-driver-$RUN_ID"
guest_elf="/tmp/rust-hypervisor-intel-$RUN_ID"

log "deploying the HyperEnclave ELF and driver source"
"${SCP[@]}" "$HE_ELF" "$HE_SSH_USER@$HE_SSH_HOST:$guest_elf"
git -C "$HE_DRIVER_DIR" archive --format=tar HEAD | \
    "${SSH[@]}" "set -eu; rm -rf -- '$guest_src'; mkdir -p '$guest_src'; tar -xf - -C '$guest_src'"

log "building the driver against the running guest kernel"
"${SSH[@]}" -n "set -eu; \
    cd '$guest_src'; \
    make -j\$(nproc); \
    ko=\$(find '$guest_src' -maxdepth 2 -name hyper_enclave.ko -print -quit); \
    test -n \"\$ko\"; \
    test -r \"\$ko\"; \
    modinfo -F vermagic \"\$ko\" | grep -F \"\$(uname -r) \" >/dev/null; \
    sudo install -m 0644 '$guest_elf' /lib/firmware/rust-hypervisor-intel"

log "unloading guest KVM modules and loading the HyperEnclave driver"
"${SSH[@]}" -n "set -eu; \
    if grep -q '^hyper_enclave ' /proc/modules; then \
        if test -r /proc/sys/dev/hyper_enclave/enabled && test \"\$(cat /proc/sys/dev/hyper_enclave/enabled)\" = 1; then \
            sudo sysctl -w dev.hyper_enclave.enabled=0; \
        fi; \
        sudo modprobe -r hyper_enclave; \
    fi; \
    if grep -q '^kvm_intel ' /proc/modules; then sudo modprobe -r kvm_intel; fi; \
    if grep -q '^kvm ' /proc/modules; then sudo modprobe -r kvm; fi; \
    ! grep -Eq '^kvm(_intel)? ' /proc/modules; \
    echo 'HE-IT-$RUN_ID-BEGIN' | sudo tee /dev/kmsg >/dev/null; \
    ko=\$(find '$guest_src' -maxdepth 2 -name hyper_enclave.ko -print -quit); \
    sudo insmod \"\$ko\" 'str_memmap=${HE_MEMMAP_START},${HE_MEMMAP_SIZE}' 'feature_mask=${HE_FEATURE_MASK}'; \
    test -c /dev/hyperenclave; \
    test \"\$(cat /proc/sys/dev/hyper_enclave/enabled)\" = 0"

log "performing HyperEnclave late launch"
timeout --foreground "${HE_ENABLE_TIMEOUT}s" "${SSH[@]}" -n \
    'sudo -n sysctl -w dev.hyper_enclave.enabled=1'
sleep 2

"${SSH[@]}" -n "set -eu; \
    test \"\$(cat /proc/sys/dev/hyper_enclave/enabled)\" = 1; \
    test -d /sys/module/hyper_enclave; \
    test -c /dev/hyperenclave"
"${SSH[@]}" -n 'sudo -n dmesg' > "$DMESG_LOG"
awk -v marker="HE-IT-$RUN_ID-BEGIN" 'index($0, marker) { found=1 } found' \
    "$DMESG_LOG" > "$RUN_DMESG_LOG"

grep -Fq "HE-IT-$RUN_ID-BEGIN" "$RUN_DMESG_LOG" || die "test log marker is missing"
grep -Fq 'The hyperenclave is opening.' "$RUN_DMESG_LOG" || \
    die "the driver did not report successful HyperEnclave opening"

online_cpus="$("${SSH[@]}" -n 'nproc')"
activation_count="$(grep -c 'Activating hypervisor on CPU' "$SERIAL_LOG" || true)"
vmx_count="$(grep -c 'successed to turn on VMX' "$SERIAL_LOG" || true)"
init_count="$(grep -Ec 'CPU [0-9]+ init OK\.' "$SERIAL_LOG" || true)"
[[ "$online_cpus" == "$HE_CPUS" ]] || die "guest has $online_cpus CPUs, expected $HE_CPUS"
[[ "$activation_count" == "$online_cpus" ]] || \
    die "only $activation_count/$online_cpus CPUs entered HyperEnclave"
[[ "$vmx_count" == "$online_cpus" ]] || \
    die "only $vmx_count/$online_cpus CPUs enabled VMX"
[[ "$init_count" == "$online_cpus" ]] || \
    die "only $init_count/$online_cpus CPUs completed HyperEnclave initialization"
grep -Fq 'Primary CPU init late...' "$SERIAL_LOG" || die "primary CPU late init is missing"
grep -Fq 'Root cell init end.' "$SERIAL_LOG" || die "root cell initialization is missing"
grep -Fq 'HyperEnclave: root of trust initialized!' "$SERIAL_LOG" || \
    die "root-of-trust initialization is missing"

failure_pattern='BUG:|Oops:|[Kk]ernel panic|soft lockup|general protection fault|unable to handle page fault|Activate hypervisor failed|return back to driver|Initialize CMRM fail|Missing hypervisor image|Version mismatch|VT-x disabled|error_code:'
if grep -E "$failure_pattern" "$RUN_DMESG_LOG" "$SERIAL_LOG" >/dev/null; then
    grep -E "$failure_pattern" "$RUN_DMESG_LOG" "$SERIAL_LOG" >&2 || true
    die "a fatal signature was found in the launch logs"
fi

log "PASS: Intel HyperEnclave is running on all $online_cpus vCPUs"
log "enabled=1; QEMU PID=$QEMU_PID"
log "artifacts: $RUN_DIR"
log "stop it with: make stop-intel-qemu"
