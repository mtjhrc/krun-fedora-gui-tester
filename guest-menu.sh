#!/usr/bin/env bash
if [[ ! -e /var/lib/libkrun-guest-ready ]]; then
    printf '\nWaiting for cloud-init to finish guest setup...\n'
    while [[ ! -e /var/lib/libkrun-guest-ready ]]; do
        sleep 2
    done
fi

while true; do
    printf '\nUsername: fedora\nPassword: fedora\n\n1) Shell\n2) Weston — accelerated GL\n3) Weston — software/Pixman\n4) GDM — graphical login (GNOME)\n5) kmscube\n6) glmark2 — DRM\n'
    read -r -p 'Select [1-6]: ' choice || exit
    case "$choice" in
        1) exec bash ;;
        2) weston --backend=drm --renderer=gl ;;
        3) weston --backend=drm --renderer=pixman ;;
        4) sudo systemctl start --no-block gdm.service ;;
        5) kmscube ;;
        6) glmark2-drm ;;
    esac
done
