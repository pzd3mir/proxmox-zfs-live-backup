# ZFS Backup System - Modular Edition

A comprehensive, production-ready backup solution for Proxmox VE systems running on ZFS. Creates complete bare-metal restore backups with hybrid approach (EFI boot partition + ZFS pool snapshots) to both NAS and USB targets with AES256 encryption.

## 🎯 What This System Does

**Creates complete system backups that let you restore your entire Proxmox server from scratch on new hardware.**

### Backup Contents
- **Boot Partition**: EFI system partition with bootloader, GRUB config, and kernel files
- **Complete ZFS Pool**: All datasets, snapshots, Proxmox configuration, VMs, and containers
- **Restore Instructions**: Detailed step-by-step recovery procedures

### Target Storage
- **Primary**: TrueNAS Scale VM (e.g., 192.168.1.100) via SMB/CIFS
- **Fallback**: USB/External drives with automatic filesystem detection
- **Encryption**: AES256 encryption for all backup files

## 🏗️ System Architecture

### Modular Design
```
zfs-backup.sh           # Main orchestrator (thin wrapper)
├── lib/utilities.sh    # Common functions (logging, colors, cleanup)
├── lib/credentials.sh  # Credential management and setup wizards
├── lib/system-detection.sh  # EFI/disk detection logic
├── lib/hybrid-backup.sh     # Core backup functions
├── lib/nas-functions.sh     # NAS-specific operations
└── lib/usb-functions.sh     # USB drive detection and backup
```

### Key Technical Features

**Device Detection**: Handles complex NVMe device naming automatically
- ZFS reports: `nvme-eui.e8238fa6bf530001001b448b4dd25f9e-part3`
- Real device: `/dev/nvme1n1p3`
- EFI partition: `/dev/nvme1n1p2`
- Supports both NVMe (`p1`, `p2`) and SATA (`1`, `2`) naming conventions

**Backup Process**:
1. Creates ZFS snapshot: `rpool@backup-YYYYMMDD-HHMM`
2. Backs up EFI boot partition with `tar + gzip + gpg`
3. Backs up ZFS pool with `zfs send -R + gzip + gpg`
4. Generates comprehensive restore instructions

**Performance**: 
- Boot partition: ~144MB in 8 seconds
- ZFS backup: ~4GB in 7.5 minutes
- Total: ~8-15 minutes for complete system backup
- Compression: 60-70% size reduction

## 🚀 Quick Start

### Initial Setup
```bash
# Set up credentials and configuration
./zfs-backup.sh setup

# Test NAS connectivity  
./zfs-backup.sh test-nas
```

### Daily Usage
```bash
# Interactive backup (recommended)
./zfs-backup.sh

# Automated backup (for cron)
./zfs-backup.sh --auto

# Custom ZFS pool
./zfs-backup.sh --pool tank
```

## ⚙️ Configuration

### Credentials File: `/root/.zfs-backup-credentials`
```bash
encryption_password=<strong_password>
nas_ip=192.168.1.100
nas_share=backups
nas_backup_path=NAS/proxmox/system-images
nas_username=backup-user
nas_password=<nas_password>
```

### Environment Variables (Alternative)
```bash
export BACKUP_ENCRYPTION_PASSWORD="your-strong-password"
export BACKUP_NAS_IP="192.168.1.100"
export BACKUP_NAS_SHARE="backups"
export BACKUP_NAS_PATH="NAS/proxmox/system-images"
export BACKUP_NAS_USER="backup-user"
export BACKUP_NAS_PASSWORD="nas-password"
```

## 🎮 Interactive Experience

### Smart Target Selection
```
🎯 BACKUP TARGET SELECTION
🔍 Detecting available backup targets...
✅ NAS is online and accessible

Available options:
1) 🌐 NAS Backup (recommended) - Fast, automatic, networked storage
2) 💾 USB Backup - Portable, offline storage

⏰ Auto-selecting NAS backup in 10 seconds...
Press any key to choose manually, or wait for auto-start...
```

### Automatic Fallback
- If NAS fails in interactive mode → automatically offers USB backup
- If no USB drives found → provides troubleshooting guidance
- Auto mode requires working NAS (no fallback for automation)

## 🔧 Advanced Usage

### Command Line Options
```bash
./zfs-backup.sh                    # Interactive hybrid backup
./zfs-backup.sh setup              # Setup credentials
./zfs-backup.sh test-nas           # Test NAS connectivity  
./zfs-backup.sh --auto             # Automated mode (cron-friendly)
./zfs-backup.sh --pool rpool       # Override ZFS pool name
./zfs-backup.sh --help             # Show help
```

### Automation Setup
```bash
# Add to root's crontab for daily backups at 2 AM
0 2 * * * /root/zfs-backup/zfs-backup.sh --auto

# Weekly backups
0 2 * * 0 /root/zfs-backup/zfs-backup.sh --auto
```

## 🛡️ Error Handling & Recovery

### Comprehensive Error Recovery
- **Snapshot exists**: Reuses existing snapshots from failed runs
- **NAS unavailable**: Automatic fallback to USB backup (interactive mode)
- **USB detection**: Handles ext4, NTFS, exFAT, FAT32 filesystems
- **Network issues**: Configurable timeouts and retry logic
- **Cleanup**: Automatic unmounting and snapshot cleanup on exit/failure

### Common Failure Scenarios
```bash
# Failed run cleanup
zfs list -t snapshot | grep backup-  # Check for leftover snapshots
zfs destroy rpool@backup-YYYYMMDD-HHMM  # Manual cleanup if needed

# NAS connection issues
./zfs-backup.sh test-nas  # Diagnose connectivity
ping 192.168.1.100       # Test network

# USB device problems
lsblk -f                  # Check available drives
mount /dev/sdb1 /mnt/test # Manual mount test
```

## 💾 Backup Output Structure

### NAS Storage Layout
```
//$NAS_IP/$NAS_SHARE/$NAS_BACKUP_PATH/
├── boot-partition-20250121-1430.tar.gz.gpg    # EFI files (~144MB)
├── zfs-backup-20250121-1430.gz.gpg            # ZFS data (~4GB)
└── RESTORE-HYBRID-20250121-1430.txt           # Recovery instructions
```

### USB Storage Layout
```
/mnt/usb-backup/
├── boot-partition-20250121-1430.tar.gz.gpg
├── zfs-backup-20250121-1430.gz.gpg  
└── RESTORE-HYBRID-20250121-1430.txt
```

## 🔄 Complete System Restore Process

### What You Get
Each backup creates **TWO encrypted files** plus **detailed instructions**:
1. **Boot partition backup** (tar.gz.gpg) - EFI system files
2. **ZFS pool backup** (gz.gpg) - Complete system data
3. **Restore instructions** (txt) - Step-by-step recovery guide

### Restore Overview
```bash
# Boot from Ubuntu Live USB
apt update && apt install -y zfsutils-linux gnupg pv gdisk

# 1. Wipe target disk and create partitions
sgdisk --zap-all /dev/nvme0n1
sgdisk --new=1:0:+512M --typecode=1:ef00 /dev/nvme0n1  # EFI
sgdisk --new=2:0:0 --typecode=2:bf00 /dev/nvme0n1      # ZFS

# 2. Restore ZFS pool
zpool create -f rpool /dev/nvme0n1p2
gpg --decrypt zfs-backup-*.gz.gpg | gunzip | pv | zfs receive -F rpool

# 3. Restore boot files  
mkfs.fat -F32 /dev/nvme0n1p1
mount /dev/nvme0n1p1 /mnt/efi
gpg --decrypt boot-partition-*.tar.gz.gpg | gunzip | tar -xf - -C /mnt/efi

# 4. Set bootfs and reboot
zpool set bootfs=rpool/ROOT/pve-1 rpool
```

## 🔒 Security Features

- **AES256 encryption** for all backup files
- **Secure credential storage** with 600 permissions
- **Automatic cleanup** of temporary credential files
- **No sensitive data** in logs or error messages
- **Passphrase required** for restore operations

## 🏥 Troubleshooting

### Backup Fails
```bash
# Check system requirements
./zfs-backup.sh --help

# Verify ZFS pool
zpool status
zfs list

# Test NAS manually
mount -t cifs //192.168.1.100/backups /mnt/test -o username=user,password=pass

# Check disk space
df -h /                    # System space
df -h /mnt/nas-mount      # NAS space
```

### Device Detection Issues
```bash
# Manual device identification
lsblk -f                   # All block devices
df /boot/efi              # EFI partition location
zpool status              # ZFS pool devices
efibootmgr -v             # Boot entries
```

### USB Problems
```bash
# USB device debugging
lsusb                     # USB devices
lsblk                     # Block devices
dmesg | tail              # Kernel messages
mount -t ext4 /dev/sdb1 /mnt/test  # Manual mount
```

## 📋 System Requirements

### Required Packages
- `zfsutils-linux` - ZFS management
- `gnupg` - Encryption/decryption  
- `cifs-utils` - NAS mounting
- `gzip` - Compression
- `tar` - Boot partition archiving

### Hardware Requirements
- **ZFS pool** (typically `rpool`)
- **EFI system partition** (usually `/boot/efi`)
- **15GB+ free space** on backup target
- **Network access** to TrueNAS (for NAS backups)

### Target Environment
- **Primary**: Proxmox VE 8.4.5 on ZFS
- **Hardware**: Compatible NAS hardware
- **Storage**: 1TB WD Black NVMe (`/dev/nvme1n1`)
- **Network**: 2.5 Gbps to TrueNAS Scale VM

## 🎯 Use Cases

### Perfect For
- **Daily Proxmox backups** before system changes
- **Pre-update snapshots** for safe rollback
- **Disaster recovery** preparation
- **Hardware migration** to new server
- **Development environment** cloning

### When to Use
```bash
# Before major changes
./zfs-backup.sh  # Interactive backup

# Regular automation  
0 2 * * * /root/zfs-backup.sh --auto  # Daily at 2 AM

# Before Proxmox updates
./zfs-backup.sh && proxmox-update

# Hardware testing
./zfs-backup.sh && test-new-config
```

## 🚨 Important Limitations

### What This System Does NOT Backup
- **TrueNAS VM drives** (backed up by TrueNAS itself)
- **Pass-through storage** (handled separately)
- **Network configuration** outside of Proxmox
- **External databases** not stored in ZFS

### Recovery Limitations  
- **Requires spare hardware** for restore testing
- **Full restore only** (no selective file recovery)
- **Encryption password** must be available
- **New hardware** may need driver updates

## 🔗 Integration Points

### TrueNAS Scale VM
- **Storage target**: Primary backup destination
- **Network**: NAS IP via SMB/CIFS (e.g., 192.168.1.100)
- **User**: `backup-user`
- **Share**: `backups` with subdirectory structure

### Proxmox Integration
- **Pre-update**: Automatic backup before system updates
- **Post-install**: Backup after VM/container changes  
- **Monitoring**: Integration with Proxmox alerting
- **Scheduling**: Native cron integration

## 📊 Performance Metrics

### Typical Backup Times
- **Boot partition**: 8 seconds (144MB → ~50MB compressed)
- **4GB ZFS pool**: 7.5 minutes over 2.5 Gbps network
- **Total process**: 8-15 minutes including prep and cleanup
- **Compression ratio**: 60-70% size reduction

### Storage Requirements
```
Original System: ~6GB
Boot partition: 144MB → ~50MB encrypted
ZFS pool: 4GB → ~1.2GB encrypted  
Total backup: ~1.3GB (vs 6GB original)
```

## 🎉 Success Indicators

### Backup Completed Successfully
```
✅ BACKUP COMPLETED SUCCESSFULLY!
📅 Completed: 2025-01-21 14:30:15
💾 Method: NAS
🔧 Mode: HYBRID (Boot + ZFS)
🔒 Encryption: AES256
📦 Compression: gzip
🗄️ Pool: rpool
📸 Snapshot: rpool@backup-20250121-1430

✅ SUCCESS INDICATORS:
• Backup files created and verified
• All processes completed without errors  
• System snapshot safely created

🚀 RECOMMENDED NEXT STEPS:
• Test backup integrity: ./integrity-check.sh
• Test restore process: Use spare hardware
• Schedule automation: Add to cron
• Store safely: Secure backup location
```

---

## 🆘 Emergency Recovery

If your system fails and you need to restore:

1. **Boot from Ubuntu Live USB**
2. **Install required tools**: `apt install zfsutils-linux gnupg pv gdisk`  
3. **Follow restore instructions** in `RESTORE-HYBRID-*.txt` file
4. **Restore takes ~15-30 minutes** depending on data size
5. **System boots exactly as backed up**

**Remember**: Keep your encryption password safe! Without it, backups are unrecoverable.

---

*Generated by ZFS Backup System - Modular Edition*