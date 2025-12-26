# ASUSTOR Flashstor eMMC Backup and Linux Installation

This guide documents how to back up the ASUSTOR Flashstor's internal eMMC and install Linux, based on [Jeff Geerling's original blog post](https://www.jeffgeerling.com/blog/2023/how-i-installed-truenas-on-my-new-asustor-nas).

## Why Replace ADM with Linux?

ASUSTOR's ADM (ASUSTOR Data Master) is a capable NAS OS, but running vanilla Linux provides:

- Full control over the system
- Access to ZFS (native, not a plugin)
- Latest software versions
- No vendor lock-in
- Better for custom media server setups

## Prerequisites

- ASUSTOR Flashstor 6 (FS6706T) or similar model
- USB keyboard connected
- HDMI monitor connected
- USB flash drive (for Ubuntu installer)
- Secondary USB drive or NVMe (for Linux installation)
- Another computer to create the installer

## Step 1: Access BIOS

1. Power off the Flashstor completely
2. Connect USB keyboard and HDMI monitor
3. Power on and **immediately spam the Delete key**
4. You should enter the AMI BIOS setup

## Step 2: Back Up the eMMC

Before disabling the eMMC, create a backup so you can restore ADM if needed.

### Option A: Boot Linux Live USB and dd the eMMC

1. Create Ubuntu Live USB on another computer
2. Boot the Flashstor from USB (change boot order in BIOS)
3. Choose "Try Ubuntu"
4. Open terminal and identify the eMMC:
   ```bash
   lsblk
   # Look for a ~8GB device, usually /dev/mmcblk0
   ```
5. Back up to USB drive:
   ```bash
   sudo dd if=/dev/mmcblk0 of=/media/ubuntu/USBDRIVE/emmc-backup.img bs=4M status=progress
   ```
6. Verify the backup:
   ```bash
   sudo dd if=/media/ubuntu/USBDRIVE/emmc-backup.img of=/dev/null bs=4M status=progress
   ```

### Option B: Network backup via SSH (if ADM is running)

If ADM is still running, you can SSH in and back up:
```bash
ssh admin@flashstor-ip
dd if=/dev/mmcblk0 | gzip | ssh user@backup-server "cat > flashstor-emmc.img.gz"
```

## Step 3: Disable eMMC in BIOS

1. Enter BIOS (Delete key on boot)
2. Navigate to: **Advanced → Storage Configuration**
3. Find **eMMC Configuration** or similar
4. Set to **Disabled**
5. Save and exit (F10)

This prevents the eMMC from being detected, ensuring Linux boots from your preferred drive.

## Step 4: Install Ubuntu

1. Boot from Ubuntu installer USB
2. Choose "Install Ubuntu"
3. **Important**: Install to your USB boot drive OR set up ZFS root on NVMe

### Recommended: ZFS Root Installation

Ubuntu 24.04 supports ZFS root out of the box:

1. Choose "Advanced Features" during install
2. Select "Use ZFS"
3. Choose your target drive (USB boot drive or NVMe)

### Alternative: USB Boot + NVMe Data Pool

For this guide, we installed Ubuntu to a fast USB 3.2 drive and created a separate ZFS pool on the NVMe drives:

1. Install Ubuntu normally to USB drive
2. After installation, create ZFS pool:
   ```bash
   sudo zpool create -f tank raidz2 nvme0n1 nvme1n1 nvme2n1 nvme3n1 nvme4n1 nvme5n1
   ```

## Step 5: Configure Boot Order

1. Enter BIOS
2. Go to **Boot** tab
3. Set your USB drive as first boot option
4. Disable or lower priority of any other boot options
5. Save and exit

## Restoring ADM (If Needed)

If you ever want to go back to ADM:

1. Enter BIOS
2. Re-enable eMMC in Storage Configuration
3. Restore the backup:
   ```bash
   # Boot from Linux Live USB
   sudo dd if=/path/to/emmc-backup.img of=/dev/mmcblk0 bs=4M status=progress
   ```
4. Set eMMC as first boot device
5. ADM should boot normally

## Troubleshooting

### Can't Enter BIOS
- Try F2 instead of Delete
- Make sure USB keyboard is in a USB 2.0 port (if available)
- Try a different keyboard

### eMMC Not Visible After Disabling
- This is expected behavior
- It will reappear when you re-enable in BIOS

### Boot Loops
- Check boot order in BIOS
- Ensure your Linux drive is bootable (EFI partition exists)
- Try reinstalling GRUB:
  ```bash
  sudo grub-install /dev/sdX
  sudo update-grub
  ```

### NVMe Drives Not Detected
- Update BIOS if available
- Check that drives are properly seated
- Some M.2 drives may need specific settings

## References

- [Jeff Geerling's Flashstor Blog Post](https://www.jeffgeerling.com/blog/2023/how-i-installed-truenas-on-my-new-asustor-nas)
- [ASUSTOR Flashstor 6 Specs](https://www.asustor.com/en/product?p_id=79)
- [Ubuntu ZFS Root Documentation](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html)
