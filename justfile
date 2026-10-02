set dotenv-load
set shell := ['bash', '-eu', '-o', 'pipefail', '-c']

worktree := env('LIBKRUN_WORKTREE', '')
port := env('SSH_PORT', '2245')
prefix := justfile_directory() / 'prefix'
image := 'Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2'
image_url := 'https://mirrors.kernel.org/fedora/releases/44/Cloud/x86_64/images/' + image

# Boot guest; download, prepare, and provision on first run
[positional-arguments]
run *args: _check _prepare
    #!/usr/bin/env bash
    set -euo pipefail
    forwarded=() kernel_override=false libkrunfw=false cmdline_override=false
    user_cmdline=
    while (($#)); do
        case "$1" in
            --kernel|--kernel=*) kernel_override=true ;;
            --libkrunfw-kernel|--libkrunfw-kernel=*) kernel_override=true; libkrunfw=true ;;
            --kernel-cmdline|--kernel-cmdline=*)
                $cmdline_override && { echo 'Repeated --kernel-cmdline' >&2; exit 1; }
                cmdline_override=true
                if [[ "$1" == --kernel-cmdline ]]; then
                    (($# >= 2)) || { echo 'Missing --kernel-cmdline value' >&2; exit 1; }
                    user_cmdline=$2
                    shift 2
                else
                    user_cmdline=${1#*=}
                    shift
                fi
                continue ;;
            --) forwarded+=("$@"); break ;;
        esac
        forwarded+=("$1")
        shift
    done
    printf 'Username: fedora\nPassword: fedora\n'
    if [[ -n '{{ worktree }}' ]]; then
        export LD_LIBRARY_PATH='{{ prefix }}/lib64'${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        launcher='{{ prefix }}/bin/gui_vm'
    else
        launcher=$(command -v gui_vm)
    fi
    exec 9>state/disk.lock
    flock -n 9 || { echo 'Guest disk already in use' >&2; exit 1; }
    runtime=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/krun-guest-XXXXXXXX")
    network= watcher= vm=
    cleanup() {
        for pid in "$watcher" "$vm" "$network"; do
            if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
        done
        rm -f "$runtime/passt.sock"
        rmdir "$runtime"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    passt -f -1 -4 -s "$runtime/passt.sock" -t '127.0.0.1/{{ port }}:22' >state/passt.log 2>&1 9>&- &
    network=$!
    for ((attempt=0; attempt<200; attempt++)); do
        [[ -S "$runtime/passt.sock" ]] && break
        kill -0 "$network" 2>/dev/null || { echo 'passt failed; inspect state/passt.log' >&2; exit 1; }
        sleep 0.05
    done
    [[ -S "$runtime/passt.sock" ]] || { echo 'passt startup timed out' >&2; exit 1; }
    format=qcow2
    [[ -f state/disk.qcow2 ]] || format=raw
    cmdline=$(jq -er .cmdline state/boot/boot.json)
    boot=()
    if ! $kernel_override; then
        boot=(--kernel "$PWD/state/boot/kernel" --kernel-format "$(jq -er .kernel_format state/boot/boot.json)" --initrd "$PWD/state/boot/initramfs")
    elif $libkrunfw && ! $cmdline_override; then
        root_device=$(jq -er '.root_device // error("Missing root metadata; run just refresh-boot")' state/boot/boot.json)
        root_fstype=$(jq -er '.root_fstype // error("Missing root metadata; run just refresh-boot")' state/boot/boot.json)
        read -ra options <<< "$cmdline"
        cmdline=
        for option in "${options[@]}"; do
            case "$option" in root=*|rootfstype=*|rd.*|init=*) continue ;; esac
            cmdline+="$option "
        done
        cmdline+="root=$root_device rootfstype=$root_fstype rootwait init=/sbin/init"
    fi
    if $cmdline_override; then cmdline=$user_cmdline; fi
    extra=()
    if [[ ! -f state/provisioned ]]; then
        dropin=$(printf '[Unit]\nRequiresMountsFor=/run/cidata\n' | base64 -w0)
        cmdline+=" ds=nocloud;s=file:///run/cidata/ systemd.mount-extra=cidata:/run/cidata:virtiofs:ro,noauto systemd.set_credential_binary=systemd.unit-dropin.cloud-init-main.service:$dropin"
        extra=(--virtiofs "cidata=$PWD/state/seed")
    fi
    "$launcher" --boot-disk "$PWD/state/disk.$format" --disk-format "$format" \
        "${boot[@]}" --kernel-cmdline "$cmdline" --acpi \
        --passt-socket "$runtime/passt.sock" \
        "${extra[@]}" "${forwarded[@]}" >state/guest.log 2>&1 9>&- &
    vm=$!
    if [[ ! -f state/provisioned ]]; then
        just _provision "$vm" 9>&- &
        watcher=$!
    fi
    wait "$vm"

[private]
_check:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n '{{ worktree }}' ]]; then
        test -x '{{ prefix }}/bin/gui_vm' && test -f '{{ prefix }}/lib64/libkrun.so' || { echo 'Missing local gui_vm/libkrun; run just build' >&2; exit 1; }
        export LD_LIBRARY_PATH='{{ prefix }}/lib64'${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        launcher='{{ prefix }}/bin/gui_vm'
    else
        launcher=$(command -v gui_vm) || { echo 'gui_vm missing; add it to PATH or set LIBKRUN_WORKTREE to automatically build it from source' >&2; exit 1; }
        library=
        IFS=: read -ra paths <<< "${LD_LIBRARY_PATH:-}"
        for directory in "${paths[@]}"; do
            if [[ -n "$directory" && -f "$directory/libkrun.so" ]]; then library="$directory/libkrun.so"; break; fi
        done
        if [[ -z "$library" ]]; then library=$(ldconfig -p | awk '$1 == "libkrun.so" {print $NF; exit}'); fi
        [[ -n "$library" && -f "$library" ]] || { echo 'libkrun.so missing from system loader lookup' >&2; exit 1; }
    fi
    help=$("$launcher" --help)
    [[ "$help" == *--boot-disk* && "$help" == *--virtiofs* ]] || { echo 'gui_vm lacks disk boot or virtiofs support' >&2; exit 1; }
    for tool in jq passt flock; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done

[private]
_prepare:
    if [[ ! -f state/boot/boot.json ]]; then just prepare; fi

[private]
_provision vm:
    #!/usr/bin/env bash
    set -euo pipefail
    ssh=(ssh -i state/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=state/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -p '{{ port }}' fedora@127.0.0.1)
    deadline=$((SECONDS + 300))
    until "${ssh[@]}" true >/dev/null 2>&1; do
        kill -0 '{{ vm }}' 2>/dev/null || { echo 'VM exited before provisioning' >&2; exit 1; }
        ((SECONDS < deadline)) || { echo 'SSH readiness timed out; inspect state/guest.log' >&2; exit 1; }
        sleep 2
    done
    echo 'Waiting for cloud-init to finish installing desktop packages...'
    status=0
    timeout 3600 "${ssh[@]}" 'sudo cloud-init status --wait --long' || status=$?
    case "$status" in
        0|2) ;;
        *) exit "$status" ;;
    esac
    "${ssh[@]}" 'rpm -q gnome-shell gnome-session gnome-session-wayland-session gdm weston weston-demo kmscube glmark2 vulkan-tools mesa-demos glx-utils mesa-vulkan-drivers && systemctl is-enabled getty@tty1.service && test "$(systemctl get-default)" = multi-user.target && sudo touch /etc/cloud/cloud-init.disabled'
    "${ssh[@]}" 'test -e /var/lib/libkrun-guest-ready && sudo systemctl restart getty@tty1.service'
    printf 'cloud-init completed\n' >state/provisioned
    echo 'Cloud-init completed; guest menu ready. VM remains running.'

# Download base image; reuse cache and resume interrupted downloads
download:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    mkdir -p cache
    [[ ! -f 'cache/{{ image }}' ]] || exit 0
    curl --fail --location --retry 3 --connect-timeout 30 --continue-at - \
        --proto '=https' --proto-redir '=https' \
        --output 'cache/{{ image }}.part' '{{ image_url }}'
    mv 'cache/{{ image }}.part' 'cache/{{ image }}'

# Create private writable disk, cloud-init seed, and boot files
prepare:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    mkdir -p state
    exec 9>state/disk.lock
    flock -n 9 || { echo 'Guest disk already in use' >&2; exit 1; }
    for path in state/disk.qcow2 state/disk.raw state/seed state/boot state/id_ed25519; do
        [[ ! -e "$path" ]] || { echo 'Guest already exists; run just clean first' >&2; exit 1; }
    done
    just download
    cp --reflink=auto 'cache/{{ image }}' state/disk.qcow2
    qemu-img resize -f qcow2 state/disk.qcow2 32G
    just _extract-boot state/disk.qcow2 state/boot
    ssh-keygen -q -t ed25519 -N '' -C libkrun-guest-tests -f state/id_ed25519
    mkdir state/seed
    cp cloud-init.yaml state/seed/user-data
    printf '\n    ssh_authorized_keys:\n      - %s\n' "$(cat state/id_ed25519.pub)" >>state/seed/user-data
    printf '  - path: /usr/local/bin/guest-menu\n    permissions: "0755"\n    content: |\n' >state/seed/menu.yaml
    sed 's/^/      /' guest-menu.sh >>state/seed/menu.yaml
    # Insert menu into write_files before users.
    sed -i '/^users:/e cat state/seed/menu.yaml' state/seed/user-data
    rm state/seed/menu.yaml
    printf 'instance-id: libkrun-%s\nlocal-hostname: libkrun-guest-tests\n' "$(cat /proc/sys/kernel/random/uuid)" >state/seed/meta-data
    printf 'version: 2\nethernets:\n  testnet:\n    match:\n      macaddress: "52:54:00:44:00:01"\n    dhcp4: true\n    dhcp6: false\n' >state/seed/network-config
    echo 'Guest prepared. Run just run.'

[private]
_extract-boot disk output:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p '{{ output }}'
    LIBGUESTFS_BACKEND=direct guestfish --ro --format="$(qemu-img info --output=json '{{ disk }}' | jq -er .format)" -a '{{ disk }}' -i copy-out /boot '{{ output }}'
    python3 prepare_image.py '{{ disk }}' '{{ output }}'
    read -ra options <<< "$(jq -er .cmdline '{{ output }}/boot.json')"
    root=
    for option in "${options[@]}"; do
        case "$option" in root=*) root=${option#root=} ;; esac
    done
    [[ "$root" == UUID=* ]] || { echo 'Expected root=UUID= in guest boot entry' >&2; exit 1; }
    guestfish=(env LIBGUESTFS_BACKEND=direct guestfish --ro --format="$(qemu-img info --output=json '{{ disk }}' | jq -er .format)" -a '{{ disk }}' -i)
    device=$("${guestfish[@]}" findfs-uuid "${root#UUID=}")
    filesystem=$("${guestfish[@]}" vfs-type "$device")
    [[ "$device" =~ ^/dev/sda([0-9]+)$ ]] || { echo "Unsupported root device: $device" >&2; exit 1; }
    jq --arg device "/dev/vda${BASH_REMATCH[1]}" --arg filesystem "$filesystem" '. + {root_device: $device, root_fstype: $filesystem}' '{{ output }}/boot.json' >'{{ output }}/boot.json.tmp'
    mv '{{ output }}/boot.json.tmp' '{{ output }}/boot.json'

# Build selected libkrun worktree and gui_vm
build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z '{{ worktree }}' ]]; then
        command -v gui_vm >/dev/null
        exit 0
    fi
    export CARGO_BUILD_JOBS=11
    make -C '{{ worktree }}' -j11 BLK=1 NET=1 GPU=1 INPUT=1 VHOST_USER=1 FFI=1 SEV=0 TDX=0 AWS_NITRO=0 PREFIX='{{ prefix }}'
    make -C '{{ worktree }}' -j11 BLK=1 NET=1 GPU=1 INPUT=1 VHOST_USER=1 FFI=1 SEV=0 TDX=0 AWS_NITRO=0 PREFIX='{{ prefix }}' install
    cargo build --manifest-path '{{ worktree }}/examples/Cargo.toml' --locked --release -j11 -p gui_vm
    install -D -m 755 '{{ worktree }}/examples/target/release/gui_vm' '{{ prefix }}/bin/gui_vm'

# Refresh extracted kernel/initramfs after guest kernel update; guest must be off
refresh-boot:
    #!/usr/bin/env bash
    set -euo pipefail
    exec 9>state/disk.lock
    flock -n 9 || { echo 'Guest disk already in use' >&2; exit 1; }
    disk=state/disk.qcow2
    [[ -f "$disk" ]] || disk=state/disk.raw
    test -f "$disk"
    output=$(mktemp -d state/boot-XXXXXXXX)
    just _extract-boot "$disk" "$output"
    previous=$(mktemp -d state/boot-previous-XXXXXXXX)
    rmdir "$previous"
    mv state/boot "$previous"
    mv "$output" state/boot

# Reset guest state, including disk and credentials; VM must be stopped
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ -d state ]] || exit 0
    exec 9>state/disk.lock
    flock -n 9 || { echo 'Guest disk already in use' >&2; exit 1; }
    gio trash state

# SSH into running guest; optional remote command
ssh *args:
    #!/usr/bin/env bash
    set -euo pipefail
    command={{ quote(args) }}
    set --
    if [[ -n "$command" ]]; then set -- "$command"; fi
    exec ssh -i state/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=state/known_hosts -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -p '{{ port }}' fedora@127.0.0.1 "$@"
