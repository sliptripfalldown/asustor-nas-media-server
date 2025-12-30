# Storage Guide

ZFS setup, memory tuning, and file sharing configuration.

## Table of Contents

- [ZFS Pool Setup](#zfs-pool-setup)
- [Directory Structure](#directory-structure)
- [ZFS Memory Tuning](#zfs-memory-tuning)
- [File Sharing](#file-sharing)

---

## ZFS Pool Setup

### Create RAIDZ2 Pool

```bash
# List available disks
lsblk

# Create RAIDZ2 pool with 6 drives (can lose 2 drives)
sudo zpool create -f tank raidz2 \
    /dev/nvme0n1 \
    /dev/nvme1n1 \
    /dev/nvme2n1 \
    /dev/nvme3n1 \
    /dev/nvme4n1 \
    /dev/nvme5n1

# Set mount point
sudo zfs set mountpoint=/tank tank

# Enable compression
sudo zfs set compression=lz4 tank

# Verify
zpool status tank
zfs list
```

### RAIDZ2 Benefits

| Feature | Value |
|---------|-------|
| Fault Tolerance | Can lose 2 drives |
| Usable Capacity | ~67% of raw capacity |
| Write Speed | Good (striped across drives) |
| Read Speed | Excellent (parallel reads) |
| Checksums | Built-in data integrity |

---

## Directory Structure

### Create Media Directories

**Important**: Downloads and library MUST be on the same filesystem for hardlinks to work.

```bash
# Create single media dataset
sudo zfs create tank/media

# Create directory structure
sudo mkdir -p /tank/media/{movies,tv,music,books,audiobooks}
sudo mkdir -p /tank/media/downloads/{radarr,sonarr,lidarr,readarr,incomplete}

# Set ownership (replace 'anon' with your username)
sudo chown -R anon:anon /tank/media
```

### Storage Layout

```
/tank/media/                    # Single ZFS dataset (enables hardlinks)
├── downloads/                  # qBittorrent downloads here
│   ├── incomplete/             # Incomplete downloads
│   ├── radarr/                 # Category folders
│   ├── sonarr/
│   ├── lidarr/
│   └── readarr/
├── movies/                     # Organized library (hardlinked from downloads)
├── tv/
├── music/
├── books/
└── audiobooks/
```

### Why Hardlinks?

When Sonarr/Radarr imports media, it can:
- **Copy**: Duplicates the file (2x space used)
- **Move**: Removes from downloads (breaks seeding)
- **Hardlink**: Points to same data on disk (no extra space)

Hardlinks only work within the same filesystem. With downloads and library under `/tank/media/`, the *arr apps hardlink instead of copy.

---

## ZFS Memory Tuning

ZFS's ARC (Adaptive Replacement Cache) can consume most of your RAM by default. On a 32GB system, it may try to use 30GB+.

### Check Current ARC Usage

```bash
cat /proc/spl/kstat/zfs/arcstats | grep -E "^size|^c_max" | awk '{print $1": "$3/1024/1024/1024" GB"}'
```

### Limit ARC Size

```bash
# Set permanent limit (8GB recommended for 32GB system)
echo "options zfs zfs_arc_max=8589934592" | sudo tee /etc/modprobe.d/zfs.conf

# Apply immediately (full effect after reboot)
echo 8589934592 | sudo tee /sys/module/zfs/parameters/zfs_arc_max
```

### Recommended ARC Sizes

| Total RAM | ARC Max | Leaves for Apps |
|-----------|---------|-----------------|
| 32 GB | 8 GB | 24 GB |
| 16 GB | 4 GB | 12 GB |
| 8 GB | 2 GB | 6 GB |

**Why limit ARC?** Large file transfers (especially over SMB) combined with uncapped ARC cause memory pressure and swap thrashing, potentially freezing the system.

---

## File Sharing

Cross-platform file sharing for ISOs, firmware, and general files.

### Create Share Dataset

```bash
# Create share dataset
sudo zfs create -o compression=lz4 tank/share
sudo zfs create tank/share/iso

# Create directory structure
sudo mkdir -p /tank/share/iso/{linux,windows,tools,firmware}
sudo chown -R anon:anon /tank/share
```

### Install Services

```bash
sudo apt install -y samba nfs-kernel-server tftpd-hpa
```

### SMB Configuration (Windows/Mac/Linux)

Add to `/etc/samba/smb.conf`:

```ini
[iso]
   comment = ISO Images and Tools
   path = /tank/share/iso
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force user = anon
   force group = anon
```

Restart: `sudo systemctl restart smbd nmbd`

### NFS Configuration (Linux/Mac - Faster)

Add to `/etc/exports`:

```
/tank/share/iso 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash,insecure)
```

Apply and restart:
```bash
sudo exportfs -ra
sudo systemctl restart nfs-server
```

### TFTP Configuration (Routers/Firmware)

Edit `/etc/default/tftpd-hpa`:

```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/tank/share/iso"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
```

Restart: `sudo systemctl restart tftpd-hpa`

### Access Methods

| Platform | Method | Example |
|----------|--------|---------|
| **Windows** | SMB | `\\192.168.10.239\iso` |
| **macOS** | SMB/NFS | Finder → ⌘K → `smb://192.168.10.239/iso` |
| **Linux** | NFS (fastest) | `sudo mount -t nfs 192.168.10.239:/tank/share/iso /mnt` |
| **Linux** | SMB | `sudo mount -t cifs //192.168.10.239/iso /mnt` |
| **rsync** | SSH (resumable) | `rsync -avhP file.iso anon@192.168.10.239:/tank/share/iso/` |
| **TFTP** | Firmware/routers | `tftp 192.168.10.239` then `get firmware/file.bin` |

### Performance Comparison

| Method | Speed | Resume | Best For |
|--------|-------|--------|----------|
| **rsync** | Fast | Yes | Large files, unreliable networks |
| **NFS** | Fastest | No | Linux/Mac clients on LAN |
| **SMB** | Slow | No | Windows compatibility only |
| **HTTP** | Good | Yes* | One-way downloads |

**Recommendation**: Use rsync for large transfers (24GB+), NFS for LAN access, SMB only when Windows requires it.

### HTTP Downloads (nginx)

The ISO share is also available via HTTP with directory browsing:

```bash
# Symlink created at /var/www/nas-portal/iso -> /tank/share/iso
sudo ln -sf /tank/share/iso /var/www/nas-portal/iso
```

nginx config (`/etc/nginx/sites-available/nas-portal`):

```nginx
location /iso {
    alias /tank/share/iso;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    sendfile on;
    tcp_nopush on;
    client_max_body_size 0;
    add_header Accept-Ranges bytes;
}
```

---

## Related Documentation

| Doc | Description |
|-----|-------------|
| [Hardware Guide](HARDWARE.md) | Hardware specs and benchmarks |
| [Services Guide](SERVICES.md) | Service configuration |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues |
