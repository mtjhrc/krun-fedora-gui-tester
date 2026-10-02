# krun-fedora-gui-tester

Fedora 44 Cloud guest for libkrun GPU/input testing. Linux x86_64, KVM,
direct kernel boot. Defaults: 4 vCPUs, 4096 MiB RAM, 32 GiB disk.

## Requirements

```sh
sudo dnf install just python3 curl qemu-img \
  guestfs-tools passt openssh-clients glib2 jq
```

Install libkrun build dependencies separately: Rust, GTK4 development headers,
virglrenderer development headers, and libkrunfw. User needs KVM/GPU access.


See [libkrunfw disk boot](LIBKRUNFW.md) for kernel configuration and current
limitations when using embedded kernel instead of Fedora guest kernel.

## Setup

```sh
cp .env.example .env
# Set LIBKRUN_WORKTREE to a clone, or leave empty for system installation.
just build # Only needed when using a clone.
just run --display 1920x1080+touch --keyboard-input
```

With `LIBKRUN_WORKTREE`, build installs libkrun and gui_vm into local `prefix/`.
Without it, gui_vm comes from `PATH` and libkrun uses normal system loader lookup.

Extra `just run` arguments pass unchanged to `gui_vm`. Specify display and
input devices yourself; none are added automatically. `gui_vm` parses and
validates these flags. Tester supplies disk, guest kernel/initramfs, root
command line, passt socket, and first-boot cloud-init share.

Kernel overrides use native `gui_vm` flags:

```sh
just run --libkrunfw-kernel --display 1920x1080 --keyboard-input
just run --kernel /path/to/kernel --kernel-format image-zstd --initrd /path/to/initramfs
```

`--kernel` omits all guest kernel/initramfs defaults. Supply matching initramfs
and format yourself. Guest root command line remains default. Libkrunfw uses
recorded root partition/filesystem instead, without initramfs; see
[required kernel options](LIBKRUNFW.md). Older prepared disks need
`just refresh-boot` to record root metadata while guest is stopped.

`--kernel-cmdline TEXT` replaces base command line. Required cloud-init arguments
are appended on first boot. Repeated command-line flags fail; conflicting
kernel flags pass to `gui_vm` for rejection. Both `--flag value` and
`--flag=value` forms work.

To use an already-running vhost-user GPU backend instead of built-in GPU:

```sh
just build # Rebuild local libkrun with vhost-user support.
just run --vhost-user-gpu /absolute/path/to/gpu.sock --display 1920x1080 --keyboard-input
```

Omit `--vhost-user-gpu` for built-in GPU.
System libkrun installations must include vhost-user support. Stop existing
guest before switching GPU backends.

First run downloads pinned Fedora Cloud 44-1.7 with curl into `cache/`.
Downloads use HTTPS, without signature or checksum verification.
Preparation copies image into `state/`, resizes QCOW2,
and extracts boot files using guestfish.
Cloud-init receives seed through virtiofs and installs GNOME, GDM, Weston, and
Mesa demos, Weston demos, kmscube, glmark2, and Vulkan tools.
VT1 logs in automatically and offers Weston GL, Weston Pixman, GDM, or shell.
Menu also includes kmscube and glmark2-drm. Ptyxis, pciutils, strace, gdb, and
wayland-utils are installed for terminal use and diagnostics.
VM stays running.
No QEMU guest boot or host filesystem mounts. Guestfish uses its own appliance
for disk access; qemu-img handles resizing. No raw conversion. Existing state is never overwritten.

**Console login: `fedora` / `fedora`.** Local testing only. Passwordless sudo enabled;
SSH uses generated key, not password. SSH listens on `127.0.0.1:2245`.
Change `SSH_PORT` in `.env` if needed.

## Commands

```sh
just run --display 1920x1080 --keyboard-input # prepare/provision on first run
just build                # install selected clone into prefix/
just download             # download base image only; resume partial download
just prepare              # download and prepare without booting
just refresh-boot         # after kernel update; guest must be stopped
just clean                # move state/ to Trash; VM must be stopped
just ssh                  # login; optional remote command
```

Bare `just` runs guest. `clean` resets disk, credentials, and all other guest
state; keeps cached base image, `prefix/`, and source clone. Next run reuses
cached image. Delete `cache/` to force download.
Download, disk preparation, launch, provisioning, and cleanup run in `justfile`
using CLI tools. `cloud-init.yaml` defines guest setup. Python only selects boot
files and detects kernel compression for libkrun.
