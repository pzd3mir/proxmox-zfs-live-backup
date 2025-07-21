#!/bin/bash
# Hybrid Backup Library - ZFS Backup System
# Performs complete hybrid backups (EFI boot partition + ZFS pool)
# Handles both NAS and USB targets with encryption and compression

# Backup hybrid system to NAS (boot partition + ZFS)
backup_hybrid_to_nas() {
    print_section_header "< HYBRID NAS BACKUP"
    print_status "Starting HYBRID backup to NAS (Boot + ZFS)..."

    local date=$(date +%Y%m%d-%H%M)
    local boot_backup_name="boot-partition-$date"
    local zfs_backup_name="$BACKUP_PREFIX-$date"

    # Detect system components if not already done
    if [ -z "$SYSTEM_DISK" ] || [ -z "$EFI_PARTITION" ]; then
        print_debug "System components not detected, running detection..."
        if ! detect_system_components; then
            print_error "Cannot detect system components for hybrid backup"
            return 1
        fi
    fi

    # Safety check for boot partition
    print_debug "Performing boot partition safety check..."
    if ! check_boot_partition_safety; then
        print_warning "Boot partition safety check failed, but continuing..."
    fi

    # Mount NAS share
    if ! mount_nas_share; then
        print_error "Failed to mount NAS share"
        return 1
    fi

    # Create ZFS snapshot AFTER successful mount
    if [ -z "$SNAPSHOT_NAME" ]; then
        if ! create_backup_snapshot; then
            print_error "Failed to create backup snapshot"
            unmount_nas_share 2>/dev/null
            return 1
        fi
    fi

    # Check available space
    local nas_space=$(df -BG "$TEMP_MOUNT" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$nas_space" -lt 15 ]; then
        print_error "Insufficient space on NAS. Need ~15GB, have ${nas_space}GB"
        umount "$TEMP_MOUNT" 2>/dev/null
        return 1
    fi

    print_status "Available NAS space: ${nas_space}GB"

    # Create backup directory
    local backup_dir="$TEMP_MOUNT/$NAS_BACKUP_PATH"
    mkdir -p "$backup_dir"
    print_debug "Created backup directory: $backup_dir"

    # STEP 1: Backup boot partition files
    print_status "=� Step 1: Backing up boot partition files..."
    local boot_backup_file="$backup_dir/$boot_backup_name.tar.gz.gpg"
    print_debug "Boot backup file: $boot_backup_file"

    local boot_start_time=$(date +%s)

    # Backup EFI files using tar (filesystem-level backup)
    if ! backup_boot_partition_files "$boot_backup_file"; then
        print_error "Boot partition backup failed"
        umount "$TEMP_MOUNT" 2>/dev/null
        return 1
    fi

    local boot_end_time=$(date +%s)
    local boot_duration=$((boot_end_time - boot_start_time))
    local boot_size=$(ls -lh "$boot_backup_file" 2>/dev/null | awk '{print $5}' || echo "unknown")

    print_status " Boot partition backup completed in ${boot_duration}s (${boot_size})"

    # STEP 2: Backup ZFS data
    print_status "=� Step 2: Streaming ZFS backup..."
    local zfs_backup_file="$backup_dir/$zfs_backup_name.gz.gpg"
    print_debug "ZFS backup file: $zfs_backup_file"

    local zfs_start_time=$(date +%s)

    if ! backup_zfs_data "$zfs_backup_file"; then
        print_error "ZFS backup failed"
        rm -f "$boot_backup_file" 2>/dev/null
        umount "$TEMP_MOUNT" 2>/dev/null
        return 1
    fi

    local zfs_end_time=$(date +%s)
    local zfs_duration=$((zfs_end_time - zfs_start_time))
    local zfs_duration_min=$((zfs_duration / 60))
    local zfs_duration_sec=$((zfs_duration % 60))
    local zfs_size=$(ls -lh "$zfs_backup_file" 2>/dev/null | awk '{print $5}' || echo "unknown")

    print_status " ZFS backup completed in ${zfs_duration_min}m ${zfs_duration_sec}s (${zfs_size})"

    # Create comprehensive restore instructions
    create_hybrid_restore_instructions "$backup_dir" "$boot_backup_name" "$zfs_backup_name" "$boot_size" "$zfs_size" "${zfs_duration_min}m ${zfs_duration_sec}s" "NAS"

    sync
    umount "$TEMP_MOUNT" 2>/dev/null

    print_section_header "<� HYBRID NAS BACKUP COMPLETED!"
    print_status "Boot partition: $boot_size (${boot_duration}s)"
    print_status "ZFS data: $zfs_size (${zfs_duration_min}m ${zfs_duration_sec}s)"
    print_status "Location: //$NAS_IP/$NAS_SHARE/$NAS_BACKUP_PATH/"
    
    return 0
}

# Backup hybrid system to USB (boot partition + ZFS)
backup_hybrid_to_usb() {
    local usb_device="$1"
    
    if [ -z "$usb_device" ]; then
        print_error "No USB device specified for backup"
        return 1
    fi

    print_section_header "=� HYBRID USB BACKUP"
    print_status "Starting HYBRID backup to USB: $usb_device"

    local date=$(date +%Y%m%d-%H%M)
    local boot_backup_name="boot-partition-$date"
    local zfs_backup_name="$BACKUP_PREFIX-$date"

    # Detect system components if not already done
    if [ -z "$SYSTEM_DISK" ] || [ -z "$EFI_PARTITION" ]; then
        print_debug "System components not detected, running detection..."
        if ! detect_system_components; then
            print_error "Cannot detect system components for hybrid backup"
            return 1
        fi
    fi

    # Mount USB device
    if ! mount_usb_device "$usb_device"; then
        print_error "Failed to mount USB device"
        return 1
    fi

    # Create ZFS snapshot AFTER successful mount
    if [ -z "$SNAPSHOT_NAME" ]; then
        if ! create_backup_snapshot; then
            print_error "Failed to create backup snapshot"
            unmount_usb_device 2>/dev/null
            return 1
        fi
    fi

    local usb_mount="$USB_MOUNT_POINT"

    # Check available space
    local usb_space_bytes=$(df -B1 "$usb_mount" | tail -1 | awk '{print $4}')
    local usb_space_gb=$((usb_space_bytes / 1024 / 1024 / 1024))

    if [ "$usb_space_gb" -lt 15 ]; then
        print_error "Insufficient space on USB. Need ~15GB, have ${usb_space_gb}GB"
        umount "$usb_mount" 2>/dev/null
        return 1
    fi

    print_status "Available USB space: ${usb_space_gb}GB"

    # STEP 1: Backup boot partition files
    print_status "=� Step 1: Backing up boot partition files..."
    local boot_backup_file="$usb_mount/$boot_backup_name.tar.gz.gpg"

    local boot_start_time=$(date +%s)

    if ! backup_boot_partition_files "$boot_backup_file"; then
        print_error "Boot partition backup failed"
        umount "$usb_mount" 2>/dev/null
        return 1
    fi

    local boot_end_time=$(date +%s)
    local boot_duration=$((boot_end_time - boot_start_time))
    local boot_size=$(ls -lh "$boot_backup_file" 2>/dev/null | awk '{print $5}' || echo "unknown")

    print_status " Boot partition backup completed in ${boot_duration}s (${boot_size})"

    # STEP 2: Backup ZFS data
    print_status "=� Step 2: Streaming ZFS backup..."
    local zfs_backup_file="$usb_mount/$zfs_backup_name.gz.gpg"

    local zfs_start_time=$(date +%s)

    if ! backup_zfs_data "$zfs_backup_file"; then
        print_error "ZFS backup failed"
        rm -f "$boot_backup_file" 2>/dev/null
        umount "$usb_mount" 2>/dev/null
        return 1
    fi

    local zfs_end_time=$(date +%s)
    local zfs_duration=$((zfs_end_time - zfs_start_time))
    local zfs_duration_min=$((zfs_duration / 60))
    local zfs_duration_sec=$((zfs_duration % 60))
    local zfs_size=$(ls -lh "$zfs_backup_file" 2>/dev/null | awk '{print $5}' || echo "unknown")

    print_status " ZFS backup completed in ${zfs_duration_min}m ${zfs_duration_sec}s (${zfs_size})"

    # Create comprehensive restore instructions
    create_hybrid_restore_instructions "$usb_mount" "$boot_backup_name" "$zfs_backup_name" "$boot_size" "$zfs_size" "${zfs_duration_min}m ${zfs_duration_sec}s" "USB"

    sync
    umount "$usb_mount" 2>/dev/null

    print_section_header "<� HYBRID USB BACKUP COMPLETED!"
    print_status "Boot partition: $boot_size (${boot_duration}s)"
    print_status "ZFS data: $zfs_size (${zfs_duration_min}m ${zfs_duration_sec}s)"
    print_status "Location: USB drive ($usb_device)"
    
    return 0
}

# Backup boot partition files (EFI system partition)
backup_boot_partition_files() {
    local backup_file="$1"
    
    if [ ! -d /boot/efi ]; then
        print_error "EFI boot directory not found at /boot/efi"
        return 1
    fi

    if [ ! -b "$EFI_PARTITION" ]; then
        print_error "EFI partition not accessible: $EFI_PARTITION"
        return 1
    fi

    print_debug "Backing up EFI files from /boot/efi to $backup_file"

    # Verify we can read the boot directory
    if ! ls /boot/efi >/dev/null 2>&1; then
        print_error "Cannot read /boot/efi directory"
        return 1
    fi

    # Create backup using tar with compression and encryption
    local temp_creds_var="BACKUP_ENCRYPTION_PASSWORD"
    local encryption_pass="${!temp_creds_var:-$ENCRYPTION_PASS}"
    
    if [ -z "$encryption_pass" ]; then
        print_error "No encryption password available"
        return 1
    fi

    # Use tar to create compressed, encrypted backup of boot files
    if tar -czf - -C /boot/efi . 2>/dev/null | \
       gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
       > "$backup_file" 2>/dev/null; then
        
        # Verify backup file was created and has content
        if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
            print_debug "Boot partition backup file created successfully"
            return 0
        else
            print_error "Boot partition backup file is empty or missing"
            rm -f "$backup_file" 2>/dev/null
            return 1
        fi
    else
        print_error "Failed to create boot partition backup"
        rm -f "$backup_file" 2>/dev/null
        return 1
    fi
}

# Backup ZFS data using snapshots
backup_zfs_data() {
    local backup_file="$1"
    
    if [ -z "$SNAPSHOT_NAME" ]; then
        print_error "No snapshot available for backup"
        return 1
    fi

    print_debug "Streaming ZFS data from snapshot: $SNAPSHOT_NAME"
    print_info "This may take 5-15 minutes depending on data size..."

    # Get encryption password
    local temp_creds_var="BACKUP_ENCRYPTION_PASSWORD"
    local encryption_pass="${!temp_creds_var:-$ENCRYPTION_PASS}"
    
    if [ -z "$encryption_pass" ]; then
        print_error "No encryption password available"
        return 1
    fi

    # Stream ZFS backup with compression and encryption
    local backup_success=false
    (
        case "$COMPRESSION" in
            "gzip")
                print_debug "Using gzip compression for ZFS backup"
                if zfs send -R "$SNAPSHOT_NAME" | gzip | \
                   gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                   > "$backup_file"; then
                    exit 0
                else
                    exit 1
                fi
                ;;
            "xz")
                print_debug "Using xz compression for ZFS backup"
                if zfs send -R "$SNAPSHOT_NAME" | xz | \
                   gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                   > "$backup_file"; then
                    exit 0
                else
                    exit 1
                fi
                ;;
            "none")
                print_debug "No compression for ZFS backup"
                if zfs send -R "$SNAPSHOT_NAME" | \
                   gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                   > "$backup_file"; then
                    exit 0
                else
                    exit 1
                fi
                ;;
            *)
                print_error "Unknown compression method: $COMPRESSION"
                exit 1
                ;;
        esac
    ) &

    local zfs_backup_pid=$!
    print_debug "ZFS backup process PID: $zfs_backup_pid"

    # Monitor ZFS backup progress with enhanced live preview
    local progress_counter=0
    local last_size=0
    local start_time=$(date +%s)
    
    while kill -0 "$zfs_backup_pid" 2>/dev/null; do
        if [ -f "$backup_file" ]; then
            local current_size=$(stat -c%s "$backup_file" 2>/dev/null || echo 0)
            if [ "$current_size" -gt 0 ]; then
                local size_mb=$((current_size / 1024 / 1024))
                local elapsed=$(($(date +%s) - start_time))
                local elapsed_min=$((elapsed / 60))
                local elapsed_sec=$((elapsed % 60))
                
                # Calculate transfer rate
                local rate_mb=0
                if [ $elapsed -gt 0 ]; then
                    rate_mb=$((size_mb / elapsed))
                fi
                
                # Show progress every 10 seconds instead of 2 minutes
                if [ $((progress_counter % 1)) -eq 0 ]; then
                    if [ $size_mb -ne $last_size ]; then
                        printf "\r💾 ZFS backup: ${size_mb}MB written | ${elapsed_min}m ${elapsed_sec}s elapsed | ~${rate_mb}MB/s avg"
                        last_size=$size_mb
                    fi
                fi
            fi
        else
            printf "\r🔄 Initializing ZFS backup stream..."
        fi
        progress_counter=$((progress_counter + 1))
        sleep 10
    done
    
    echo ""  # New line after progress display

    # Wait for backup process to complete
    wait "$zfs_backup_pid"
    local backup_result=$?

    if [ $backup_result -eq 0 ] && [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        print_debug "ZFS backup completed successfully"
        return 0
    else
        print_error "ZFS backup failed with exit code: $backup_result"
        rm -f "$backup_file" 2>/dev/null
        return 1
    fi
}

# Create comprehensive restore instructions for hybrid backups
create_hybrid_restore_instructions() {
    local target_dir="$1"
    local boot_backup_name="$2"
    local zfs_backup_name="$3"
    local boot_size="$4"
    local zfs_size="$5"
    local duration="$6"
    local method="$7"
    local date=$(date +%Y%m%d-%H%M)

    local restore_file="$target_dir/RESTORE-HYBRID-$date.txt"
    
    cat > "$restore_file" << EOF
= HYBRID ENCRYPTED BACKUP RESTORE INSTRUCTIONS
===============================================
Backup Date: $(date)
Boot Partition File: $boot_backup_name.tar.gz.gpg ($boot_size)
ZFS Data File: $zfs_backup_name.gz.gpg ($zfs_size)
Total Duration: $duration
Method: $method backup
Pool: $ZFS_POOL
Compression: $COMPRESSION
Encryption: $ENCRYPTION_ALGO

�  CRITICAL: You need the encryption password to restore!

COMPLETE SYSTEM RESTORE (HYBRID METHOD):
========================================
This backup contains TWO files:
 Boot partition files: $boot_backup_name.tar.gz.gpg
 Complete ZFS pool data: $zfs_backup_name.gz.gpg

RESTORE PROCEDURE:
==================
1. Boot target system from Linux live USB (Ubuntu, Debian, etc.)
2. Install tools:
   apt update && apt install -y zfsutils-linux gnupg pv gdisk xz-utils tar

3. Connect backup drive and locate both backup files

4. Identify target disk (e.g., /dev/nvme0n1, /dev/sda)
   �  WARNING: Target disk will be COMPLETELY ERASED!

5. STEP 1 - Create partition table:
   # Wipe disk completely
   sgdisk --zap-all /dev/TARGET_DISK

   # Create partitions
   sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI System" /dev/TARGET_DISK
   sgdisk --new=2:0:0 --typecode=2:bf00 --change-name=2:"ZFS Pool" /dev/TARGET_DISK

   # Format EFI partition
   mkfs.fat -F32 /dev/TARGET_DISKp1

6. STEP 2 - Restore ZFS data:
   # Create ZFS pool on second partition
   zpool create -f $ZFS_POOL /dev/TARGET_DISKp2

   # Restore ZFS data
   gpg --decrypt $zfs_backup_name.gz.gpg | \\
   $([ "$COMPRESSION" = "gzip" ] && echo "gunzip" || echo "unxz") | \\
   pv | zfs receive -F $ZFS_POOL

7. STEP 3 - Restore boot files:
   # Mount EFI partition
   mkdir -p /mnt/efi
   mount /dev/TARGET_DISKp1 /mnt/efi

   # Restore boot files from tar backup
   gpg --decrypt $boot_backup_name.tar.gz.gpg | gunzip | tar -xf - -C /mnt/efi

   # Set bootfs property (find your root dataset with: zfs list | grep ROOT)
   zpool set bootfs=$ZFS_POOL/ROOT/pve-1 $ZFS_POOL
   # Note: Replace 'pve-1' with your actual root dataset name if different

   # Unmount EFI partition
   umount /mnt/efi

8. Reboot and remove live USB
9. System should boot exactly as it was when backed up

ADVANTAGES OF HYBRID METHOD:
============================
 Fast daily backups (only changed ZFS data)
 Safe live system backup (no boot conflicts)
 Complete bootable restore
 Small backup files (efficient compression)
 Incremental ZFS snapshots supported

VERIFICATION:
=============
After restore, verify:
- System boots normally
- All VMs and containers are present
- ZFS pool is healthy: zpool status
- All datasets mounted: zfs list

BACKUP CONTENTS:
================
Boot Partition ($boot_size):
 EFI System Partition with bootloader
 GRUB configuration
 Kernel boot files

ZFS Data ($zfs_size):
 Complete ZFS pool: $ZFS_POOL
 All datasets and snapshots
 Proxmox configuration
 All VMs and containers
 File permissions and attributes

EMERGENCY NOTES:
================
- If system doesn't boot, check EFI boot entries: efibootmgr -v
- Verify ZFS pool import: zpool import $ZFS_POOL
- Check partition types: lsblk -f
- Regenerate initramfs if needed: update-initramfs -u

Created: $(date)
Script: ZFS Backup System (Modular Edition)
Boot Partition: EFI System Partition
ZFS Pool: $ZFS_POOL
EOF

    print_debug "Restore instructions written to: $restore_file"
    return 0
}