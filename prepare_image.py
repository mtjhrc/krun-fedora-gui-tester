#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Select extracted Fedora boot files for libkrun direct boot."""

import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys


def parse_entry(text):
    fields = {}
    for line in text.splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            parts = line.split(maxsplit=1)
            if len(parts) != 2:
                raise RuntimeError("Malformed Boot Loader Specification field")
            name, value = parts
            fields.setdefault(name, []).append(value.strip())
    for name in ("linux", "options"):
        if len(fields.get(name, [])) != 1:
            raise RuntimeError(f"Boot entry needs exactly one {name} field")
    if not fields.get("initrd"):
        raise RuntimeError("Boot entry has no initramfs")
    options = fields["options"][0].split()
    if any("$" in option for option in options):
        raise RuntimeError("Boot entry uses unresolved GRUB variables")
    if not any(option.startswith("root=") for option in options):
        raise RuntimeError("Boot entry has no root device")
    options = [option for option in options
               if option not in ("ro", "rw", "quiet", "rhgb")
               and not option.startswith("console=")]
    options.extend(["rw", "console=hvc0", "rd.driver.pre=virtio_mmio", "no_timer_check"])
    return {"version": fields.get("version", [""])[0],
            "linux": fields["linux"][0], "initrd": fields["initrd"],
            "cmdline": " ".join(dict.fromkeys(options))}


def boot_path(boot, value):
    if ".." in PurePosixPath(value).parts:
        raise RuntimeError("Unsafe path in boot entry")
    relative = value.removeprefix("/").removeprefix("boot/")
    candidate = (boot / relative).resolve()
    if not candidate.is_relative_to(boot.resolve()) or not candidate.is_file():
        raise RuntimeError(f"Boot entry file unavailable: {value}")
    return candidate


def kernel_format(path):
    data = path.read_bytes()
    if data.startswith(b"\x7fELF"):
        return "elf"
    if data[0x202:0x206] != b"HdrS":
        raise RuntimeError("Expected x86_64 ELF or Linux bzImage")
    payload_start = (data[0x1f1] + 1) * 512
    payload_start += int.from_bytes(data[0x248:0x24c], "little")
    payload = data[payload_start:]
    for magic, name in [(b"\x28\xb5\x2f\xfd", "image-zstd"),
                        (b"\x1f\x8b\x08", "image-gz"), (b"BZh", "image-bz2")]:
        if payload.startswith(magic):
            return name
    raise RuntimeError("Kernel compression is not supported by libkrun")


def extract(image, output):
    boot = output / "boot"
    entries = [path for path in (boot / "loader/entries").glob("*.conf")
               if "rescue" not in path.name]
    if not entries:
        raise RuntimeError("No non-rescue Boot Loader Specification entries found")
    # Numeric version sorting puts 6.19 after 6.9.
    entries.sort(key=lambda path: [f"{int(part):020d}" if part.isdigit() else part
                                  for part in re.split(r"(\d+)", path.name)])
    entry_path = entries[-1]
    entry = parse_entry(entry_path.read_text())
    kernel = boot_path(boot, entry["linux"])
    initrds = [boot_path(boot, name) for name in entry["initrd"]]
    shutil.copyfile(kernel, output / "kernel")
    with (output / "initramfs").open("wb") as destination:
        for initrd in initrds:
            with initrd.open("rb") as source:
                shutil.copyfileobj(source, destination)
    metadata = {"version": entry["version"], "entry": entry_path.name,
                "kernel_format": kernel_format(kernel), "cmdline": entry["cmdline"],
                "source_image": str(image.resolve())}
    (output / "boot.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Extracted {entry['version']} to {output}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: prepare_image.py DISK EXTRACTED_DIRECTORY")
    try:
        extract(Path(sys.argv[1]), Path(sys.argv[2]))
    except (RuntimeError, OSError) as error:
        sys.exit(f"error: {error}")
