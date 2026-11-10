# jetflash: flash a Jetson Orin Nano with Ubuntu 22.04 from Docker

This repo is a single Ubuntu 22.04 container plus one script, `jetflash.sh`. You plug in a Jetson Orin
Nano in recovery mode, and the script detects it and flashes **JetPack 6.2.3 (Ubuntu 22.04)** to the
NVMe SSD.

---

## 1. Which version to flash

| Item | Version | Notes |
|---|---|---|
| **JetPack** | **6.2.3** | The newest JetPack that ships Ubuntu 22.04. Released Aug 2026. |
| **Jetson Linux (L4T)** | **R36.5.2** | The OS/BSP inside JetPack 6.2.3. This is the default `L4T_VERSION`. |
| **Ubuntu (on the Jetson)** | **22.04 LTS** | NVIDIA's sample root filesystem is based on 22.04 (Jammy). |
| **Linux kernel** | 5.15 | |
| **Host/container OS** | Ubuntu 22.04 | A supported flashing host for R36 (the container gives you this on any distro). |
| **Board config** | `jetson-orin-nano-devkit-super` | Super Mode (up to 67 TOPS) is supported since JetPack 6.2. |

### Why not something else?
- **JetPack 7.x (L4T R39.x)** supports Orin from 7.2 onward, but it is **Ubuntu 24.04** with kernel 6.8,
  so it is the wrong choice if you need Ubuntu 22.04.
- **JetPack 5.x (L4T R35.x)** is **Ubuntu 20.04**.
- Older JetPack 6 releases all use Ubuntu 22.04 and work here. Set `L4T_VERSION` to choose one:

| JetPack | L4T | Released |
|---|---|---|
| 6.2.3 | 36.5.2 | Aug 2026 (**default, recommended**) |
| 6.2.2 | 36.5.0 | Feb 2026 |
| 6.2.1 | 36.4.4 | Jun 2025 |
| 6.2   | 36.4.3 | Jan 2025 |
| 6.1   | 36.4   | Sep 2024 |
| 6.0   | 36.3   | May 2024 |

Downloads used by the script (fetched automatically):
- `https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.2/releases/Jetson_Linux_r36.5.2_aarch64.tbz2`
- `https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.2/releases/Tegra_Linux_Sample-Root-Filesystem_r36.5.2_aarch64.tbz2`

---

## 2. What you need

- A Linux PC (x86_64) with Docker and Docker Compose v2.
- About **40 GB** of free disk space for the BSP, the rootfs and the flash images.
- Jetson Orin Nano Developer Kit carrier with an Orin Nano (4GB/8GB) or **Orin NX (8GB/16GB)** module and an
  **M.2 NVMe SSD** installed. Third-party carriers (Seeed reComputer and others) need the maker's own BSP.
- A USB-C **data** cable. Some cables only carry power and will not work.
- A jumper wire for recovery mode.

---

## 3. Files

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 22.04 image with all of NVIDIA's host-side flashing dependencies. |
| `docker-compose.yml` | Privileged container with `/dev` passthrough and host networking. Mounts `./workspace`. |
| `jetflash.sh` | The single script that does everything (see below). |
| `workspace/` | Created automatically. Holds the downloads and the prepared BSP. Wiped and rebuilt on every run. |

What `jetflash.sh` does:
1. Sets up qemu-aarch64 and starts the NFS server the flash needs.
2. **Every run:** deletes the previous downloads and BSP, downloads L4T R36.5.2 and the Ubuntu 22.04
   rootfs fresh, then runs `apply_binaries.sh`. It can optionally create a user on the Jetson.
3. Waits until a Jetson in recovery mode appears on USB: `0955:7523` = Orin Nano 8GB, `0955:7623` = Orin Nano 4GB,
   `0955:7323` = Orin NX 16GB, `0955:7423` = Orin NX 8GB. All of them use the same `jetson-orin-nano-devkit-super`
   config on the dev kit carrier.
4. **Wipes the target drive completely** with `--erase-all`. NVIDIA's flash tool runs `blkdiscard` on the
   whole NVMe SSD, which erases every partition and all data on it. Then it creates a fresh partition
   table.
5. Runs `l4t_initrd_flash.sh` to flash the QSPI bootloader and Ubuntu 22.04 to the NVMe SSD.

---

## 4. One-time host setup

```bash
# NFS kernel module: the flash boots the Jetson over USB networking with an NFS rootfs
sudo modprobe nfsd
echo nfsd | sudo tee /etc/modules-load.d/nfsd.conf     # optional: load it on every boot

# Optional but recommended: stop the desktop from auto-mounting the Jetson's disks mid-flash
sudo systemctl stop udisks2
```

Build the image:
```bash
cd jetflash
docker compose build
```

### Container login
The container runs as a normal (non-root) user that has passwordless `sudo`. `jetflash.sh` switches to
root automatically.

| Username | Password |
|---|---|
| `jetflash` | `jetflash` |

To change them, edit `ARG USERNAME` / `ARG PASSWORD` in the `Dockerfile` and rebuild, or run
`docker compose build --build-arg USERNAME=me --build-arg PASSWORD=secret`.

---

## 5. Flash the Jetson

### Step 1: Start the script
```bash
docker compose run --rm jetflash
```
Optional: to create a login user on the Jetson and skip its first-boot setup wizard, run this instead:
```bash
JETSON_USER=me JETSON_PASS='secret' JETSON_HOST=orin docker compose run --rm jetflash
```
Every run downloads about 2 GB fresh and prepares the rootfs, which takes 10–30 minutes. When the script
prints `Waiting for a Jetson Orin Nano in recovery mode...`, move on to step 2.

### Step 2: Put the Jetson into recovery mode
1. Power off the Jetson.
2. Connect **FC REC** to **GND** with the jumper. On the dev kit's button header under the module,
   these are pins 9 and 10.
3. Connect the USB-C port on the Jetson to your PC.
4. Plug in power.

The script detects the board automatically and starts flashing. Flashing takes about 10–20 minutes.

> ⚠️ **Everything on the Jetson's SSD is erased** (or on the SD card or USB drive if you chose `sd` or
> `usb`). There is no confirmation prompt. Back up anything you need first.

### Step 3: Finish
When you see `Flash complete`:
1. Remove the jumper.
2. Unplug the USB-C cable.
3. Power-cycle the Jetson.

It boots Ubuntu 22.04 from the NVMe SSD. Unless you set `JETSON_USER`/`JETSON_PASS`, the setup wizard
runs on first boot (with a monitor and keyboard attached).

Check the version on the Jetson:
```bash
cat /etc/nv_tegra_release    # expect: R36 (release), REVISION: 5.2
lsb_release -a               # expect: Ubuntu 22.04
```

---

## 6. Options

| How | Effect |
|---|---|
| `docker compose run --rm jetflash jetflash.sh sd` | Flash a microSD card instead of NVMe (`usb` = USB drive). |
| `docker compose run --rm jetflash jetflash.sh nvme jetson-orin-nano-devkit` | Use the original (non-Super) power modes. |
| `L4T_VERSION=36.4.4 docker compose run --rm jetflash` | Flash a different JetPack 6 release (see the table in section 1). |
| `LOOP=1 docker compose run --rm jetflash` | After each flash, wait for the next Jetson and flash it too. |
| `docker compose run --rm jetflash bash` | Open a shell in the container as `jetflash` for debugging (`sudo -i` for root). |

Each run starts from scratch, so a new user or version takes effect on the next run. With `LOOP=1`,
the files are downloaded once at the start and reused for every board flashed in that session.

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| Script waits forever | Run `lsusb` on the host. You should see `0955:7323`, `7423`, `7523` or `7623`. If not, check the jumper, use a USB-C **data** cable, and try a different port (avoid hubs). |
| `host kernel has no nfsd` | Run `sudo modprobe nfsd` on the host. |
| Flash stalls at "Waiting for target to boot-up" | Stop udisks2 (section 4). Check that no firewall (ufw/firewalld) blocks NFS on `usb0`/`l4tbr0`. Re-enter recovery mode and retry. |
| `nvme0n1p1 not found` | The SSD is not detected. Reseat it in the M.2 slot (Key M, 2280). |
| Flash fails on a board that came with very old firmware (JetPack 5.x) | Flashing with this tool also updates the QSPI firmware, so a full retry usually works. Power-cycle the board in recovery mode and run again. |
| `NFS server is not running` / `clnt_create: RPC: Timed out` | Something else held the RPC port (111). The script now resets RPC before each flash; just re-run it. If it reports port 111 in use, stop the host's own NFS (`sudo systemctl stop rpcbind rpcbind.socket nfs-server`). |
| `another jetflash run is already active` | Only one run at a time; a second run would wipe the first one's files. Stop the other one with `docker ps --filter name=jetflash` then `docker stop <name>`. |
| `Please install the Secureboot package...` | Harmless. NVIDIA prints it but continues. Only matters for boards with secure-boot fuses burned. |
| Want to inspect logs | Logs are in `workspace/r36.5.2/Linux_for_Tegra/initrdlog/`. |

---

## 8. Security note

The container runs `privileged` with the host's `/dev` and host networking. The Jetson re-enumerates
as different USB devices and a network interface during flashing, so this access is required. Only run
the container while you are flashing.

---

## Sources
- [Jetson Linux archive (all L4T versions)](https://developer.nvidia.com/embedded/jetson-linux-archive)
- [Jetson Linux R36.5.2 release page](https://developer.nvidia.com/embedded/jetson-linux-r3652)
- [JetPack 6.2.3 / Jetson Linux 36.5.2 announcement](https://forums.developer.nvidia.com/t/jetpack-6-2-3-jetson-linux-36-5-2-is-now-live/379873)
- [JetPack 6.2.2 / Jetson Linux 36.5 announcement](https://forums.developer.nvidia.com/t/jetpack-6-2-2-jetson-linux-36-5-is-now-live/359624)
- [JetPack 7.2 / Jetson Linux 39.2 release notes (Ubuntu 24.04)](https://docs.nvidia.com/jetson/archives/r39.2/ReleaseNotes/Jetson_Linux_Release_Notes_r39.2.pdf)
