# Hardware Guide

Hardware specifications, benchmarks, and optimization for the ASUSTOR Flashstor 6 NAS build.

## Table of Contents

- [Hardware Specifications](#hardware-specifications)
- [Performance Benchmarks](#performance-benchmarks)
- [Temperature Monitoring](#temperature-monitoring)
- [Fan Control](#fan-control)
- [Hardware Recommendations](#hardware-recommendations)

---

## Hardware Specifications

### Base Unit: ASUSTOR Flashstor 6 (FS6706T)

A compact 6-bay all-flash NAS with Intel Jasper Lake.

| Component | Specification |
|-----------|---------------|
| CPU | Intel Celeron N5105 @ 2.00GHz (4 cores, burst to 2.9GHz) |
| Architecture | Jasper Lake, 10nm |
| Base RAM | 4GB DDR4 (soldered) |
| Drive Bays | 6x M.2 NVMe slots (PCIe 3.0 x1 each) |
| Network | 2x 2.5 Gigabit Ethernet |
| USB | 3x USB 3.2 Gen1 |
| HDMI | 1x HDMI 2.0 (4K output) |
| Form Factor | Compact desktop |

### Upgrades

| Upgrade | Part | Notes |
|---------|------|-------|
| **RAM** | PNY Performance 32GB (2x16GB) DDR4 3200MHz | Model: MD32GK2D4320016-TB, CL22 |
| **Boot Drive** | TEAM 512GB C212 USB 3.2 Gen2 Flash Drive | Model: TC2123512GB01. Ubuntu on USB |
| **NVMe Drives** | 5x Xiede XF-2TB2280 + 1x Timetec 2TB | Budget NVMe, ~$80-100 each |

### Why USB Boot?

The FS6706T has a small internal eMMC for stock ADM OS. To run Linux:

1. **Back up the eMMC** following [Jeff Geerling's guide](https://www.jeffgeerling.com/blog/2023/how-i-installed-truenas-on-my-new-asustor-nas)
2. **Disable eMMC in BIOS** (Advanced → Storage Configuration → eMMC → Disabled)
3. **Set USB as first boot device**
4. **Install Ubuntu to USB drive** with ZFS root on the NVMe pool

This preserves the option to restore ADM later while giving full Linux control.

---

## Performance Benchmarks

Real-world benchmarks from this exact system.

### ZFS Pool Performance (RAIDZ2, 6x NVMe)

| Test | Result | Notes |
|------|--------|-------|
| **Sequential Write** | 1.8 GB/s | `dd if=/dev/zero bs=1M count=4096` |
| **Sequential Read** | 4.0 GB/s | `dd if=testfile of=/dev/null bs=1M` |
| **IOPS (random)** | ~50,000+ | Limited by PCIe 3.0 x1 per slot |
| **Usable Capacity** | 7.3 TB | 6x 2TB in RAIDZ2 (can lose 2 drives) |

### Network Performance

| Interface | Speed | Notes |
|-----------|-------|-------|
| bond0 | 2.5 Gbps | Primary network (bonded NICs) |
| veth-vpn | 1 Gbps | VPN namespace bridge |
| proton0 | ~200 Mbps | WireGuard tunnel (in VPN namespace) |

### System Resources

| Metric | Value |
|--------|-------|
| Total RAM | 32 GB |
| Typical Usage | 17 GB (with all services) |
| CPU Load | 0.8 average (idle with services) |
| Power Draw | ~25-35W typical |

### Intel Quick Sync (N5105)

| Codec | Decode | Encode | Notes |
|-------|--------|--------|-------|
| H.264 | Yes | CQP only | VBR not supported |
| HEVC 8-bit | Yes | CQP only | VBR not supported |
| HEVC 10-bit | Yes | CQP only | VBR not supported |
| VP9 | Yes | No | |
| AV1 | No | No | |

**Note**: Hardware encoding requires VBR (Variable Bit Rate) for Jellyfin mobile streaming, which N5105 doesn't support. Hardware decoding and HDR tone mapping still work - only encoding falls back to CPU.

---

## Temperature Monitoring

### Install ASUSTOR Platform Driver

The FS6706T uses an IT8625 chip for hardware monitoring.

```bash
# Clone the driver
cd ~
git clone https://github.com/mafredri/asustor-platform-driver.git
cd asustor-platform-driver

# Build
make

# Install to kernel modules
sudo cp *.ko /lib/modules/$(uname -r)/kernel/drivers/hwmon/
sudo depmod -a

# Configure automatic loading at boot
echo -e "asustor\nasustor_it87" | sudo tee /etc/modules-load.d/asustor.conf

# Load now
sudo modprobe asustor
sudo modprobe asustor_it87
```

### Check Sensors

```bash
# View all temperatures and fan speeds
sensors

# Key readings:
# - coretemp (CPU): Target < 55°C for heavy workloads
# - it8625 (fan1): Main case fan
# - nvme: NVMe drive temps (should be < 50°C)
```

### Temperature Targets

| Component | Target | Critical |
|-----------|--------|----------|
| CPU (coretemp) | < 55°C | 105°C |
| NVMe drives | < 50°C | 70°C |
| Network adapter | < 60°C | 120°C |

### Monitor Script

Quick script to monitor temps:

```bash
#!/bin/bash
# Save as ~/scripts/monitor-temps.sh
while true; do
    clear
    echo "=== Temperature Monitor ==="
    sensors | grep -E "Package|Core|fan1|Composite"
    sleep 5
done
```

---

## Fan Control

### Set Maximum Fan Speed

For systems running heavy transcoding/download workloads:

```bash
# Find the PWM control (usually hwmon10 for it8625)
ls /sys/class/hwmon/*/name | while read f; do echo "$f: $(cat $f 2>/dev/null)"; done

# Set fan to 100% (255 PWM)
sudo sh -c 'echo 255 > /sys/class/hwmon/hwmon10/pwm1'

# Verify
sensors | grep fan1
```

### Persistent Fan Settings (Systemd)

Create a service to set fans to maximum at boot:

```bash
sudo tee /etc/systemd/system/asustor-fanmax.service << 'EOF'
[Unit]
Description=Set ASUSTOR fans to maximum
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for pwm in /sys/class/hwmon/*/pwm1; do [ -f "$pwm" ] && echo 255 > "$pwm"; done'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable asustor-fanmax.service
```

### Fan Speed Reference

| PWM Value | Speed | Use Case |
|-----------|-------|----------|
| 50 | ~20% (~1400 RPM) | Idle, quiet |
| 128 | ~50% (~2500 RPM) | Light load |
| 180 | ~70% (~3500 RPM) | Moderate load |
| 255 | 100% (~4300 RPM) | Heavy transcoding/downloads |

---

## Hardware Recommendations

### For Similar Builds

| Budget | Recommendation |
|--------|----------------|
| **CPU** | N5105/N6005 is plenty for transcoding-free streaming |
| **RAM** | 32GB recommended for ZFS ARC cache + services |
| **NVMe** | Mix brands/batches to reduce simultaneous failure risk |
| **Boot** | High-endurance USB 3.2 drive or small SATA SSD via adapter |
| **UPS** | Strongly recommended for ZFS - unclean shutdown can cause issues |

### Performance Notes

- The N5105's Quick Sync handles 4K HEVC decoding if needed
- Each M.2 slot is PCIe 3.0 x1 (~1GB/s max per drive)
- RAIDZ2 overhead + x1 lanes = real-world ~1.8GB/s write
- 2.5GbE is the bottleneck for network transfers (~300MB/s max)

---

## Related Documentation

| Doc | Description |
|-----|-------------|
| [Storage Guide](STORAGE.md) | ZFS setup and file sharing |
| [Building Guide](BUILDING.md) | Compiling software from source |
| [Services Guide](SERVICES.md) | Service configuration |
