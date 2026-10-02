# libkrunfw configuration for Fedora GUI guests

To run fully featured Fedora with desktop UI, enable these additional kernel
options in libkrunfw.

Change `config-libkrunfw_x86_64`:

```text
CONFIG_AUTOFS_FS=y
# CONFIG_BASE_SMALL is not set
CONFIG_FB=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_FRAMEBUFFER_CONSOLE=y
```

- **Autofs:** supports systemd automount units.
- **Disable BASE_SMALL:** allows Fedora's `kernel.pid_max=4194304`.
- **Framebuffer console:** displays TTY1 boot menu and activates VM window
  before GDM or Weston starts.

Optional: enable `CONFIG_BTRFS_FS_POSIX_ACL=y` to avoid journald ACL warnings.

Autofs and PID-limit fixes are boot-tested with Fedora 44 and kernel 6.12.109.
