# Hardware Guide

Hardware specifications, benchmarks, and optimization for the ASUSTOR Flashstor 6 NAS build.

## Table of Contents

- [Hardware Specifications](#hardware-specifications)
- [Performance Benchmarks](#performance-benchmarks)
- [Temperature Monitoring](#temperature-monitoring)
- [Fan Control](#fan-control)
- [LED Control](#led-control)
- [Hardware Control Script](#hardware-control-script)
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

### Automatic Fan Control (Recommended)

The system uses `fancontrol` for automatic temperature-based fan speed:

```bash
# Install automatic fan control
sudo ./scripts/setup-hardware-controls.sh
```

This configures a fan curve based on CPU temperature:
- Below 40°C: ~30% speed (quiet)
- 40-65°C: Linear ramp to 100%
- Above 65°C: 100% (full speed)

### Manual Fan Control

```bash
# Set fan to specific PWM (0-255)
./scripts/hardware-control.sh fan 128    # 50% speed

# Enable automatic mode
./scripts/hardware-control.sh fan auto

# Check current status
./scripts/hardware-control.sh fan
```

### Fan Speed Reference

| PWM Value | Speed | Use Case |
|-----------|-------|----------|
| 80 | ~30% (~2200 RPM) | Idle, quiet |
| 128 | ~50% (~2800 RPM) | Light load |
| 180 | ~70% (~3500 RPM) | Moderate load |
| 255 | 100% (~4300 RPM) | Heavy transcoding/downloads |

### Fancontrol Configuration

The configuration is stored in `/etc/fancontrol`:

```bash
# View current configuration
cat /etc/fancontrol

# Restart after changes
sudo systemctl restart fancontrol
```

---

## LED Control

The Flashstor 6 has multiple controllable LEDs via the asustor-platform-driver.

### Available LEDs

| LED | Purpose | Default State |
|-----|---------|---------------|
| `blue:power` | Power indicator | On |
| `red:power` | Power error | Off |
| `green:status` | System status | On |
| `red:status` | System error | Off (panic trigger) |
| `blue:lan` | Network activity | On |
| `nvme1:green:disk` | Disk activity | On (disk-activity trigger) |
| `nvme1:red:disk` | Disk error | Off |
| `red:side_inner/mid/outer` | Side accent LEDs | On |

### LED Triggers

LEDs can be set to respond to system events:

```bash
# Set disk LED to blink on activity
./scripts/hardware-control.sh led nvme1:green:disk trigger disk-activity

# Turn off side LEDs (stealth mode)
./scripts/hardware-control.sh side off

# View available triggers
./scripts/hardware-control.sh led green:status trigger
```

Available triggers: `none`, `disk-activity`, `disk-read`, `disk-write`, `cpu`, `panic`, and others.

### Boot Configuration

LED triggers are configured at boot via `asustor-leds.service`:

```bash
# Check service status
systemctl status asustor-leds

# Modify boot configuration
sudo nano /usr/local/bin/asustor-led-setup.sh
```

---

## Hardware Control Script

A unified script for all hardware controls:

```bash
./scripts/hardware-control.sh [command]
```

### Commands

| Command | Description |
|---------|-------------|
| `status` | Show all hardware status |
| `temps` | Show all temperature sensors |
| `fan [0-255\|auto\|manual]` | Control fan speed |
| `led <name> [0\|1]` | Set LED on/off |
| `led <name> trigger [name]` | Set LED trigger |
| `leds` | List all available LEDs |
| `blink [on\|off]` | Control status LED blinking |
| `side [on\|off]` | Control side accent LEDs |

### Examples

```bash
# Show full status
./scripts/hardware-control.sh status

# Set fan to 50%
./scripts/hardware-control.sh fan 128

# Turn off annoying blinking LED
./scripts/hardware-control.sh blink off

# Enable disk activity LED
./scripts/hardware-control.sh led nvme1:green:disk trigger disk-activity

# Stealth mode - turn off all LEDs
./scripts/hardware-control.sh side off
./scripts/hardware-control.sh led blue:power 0
```

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
