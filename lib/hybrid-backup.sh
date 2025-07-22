#!/bin/bash
# Hybrid Backup Library - ZFS Backup System
# Performs complete hybrid backups (EFI boot partition + ZFS pool)
# Handles both NAS and USB targets with encryption and compression

# Backup hybrid system to NAS (boot partition + ZFS)
backup_hybrid_to_nas() {
    echo "HYBRID NAS BACKUP"
    echo "================="
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

    echo "HYBRID BACKUP COMPLETED!"
    echo "========================="
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

    echo "HYBRID USB BACKUP"
    echo "================="
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

    echo "HYBRID BACKUP COMPLETED!"
    echo "========================="
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
            # Quick verification - test GPG decryption
            if echo "$encryption_pass" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | head -c 1024 >/dev/null; then
                print_debug "Boot partition backup created and verified successfully"
                return 0
            else
                print_error "Boot partition backup verification failed"
                rm -f "$backup_file" 2>/dev/null
                return 1
            fi
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
    case "$COMPRESSION" in
        "lz4")
            print_debug "Using lz4 compression for ZFS backup (fast)"
            if command -v pv >/dev/null 2>&1; then
                zfs send -R "$SNAPSHOT_NAME" | pv -N "ZFS backup" | lz4 | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file"
            else
                zfs send -R "$SNAPSHOT_NAME" | lz4 | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file" &
                local pid=$!
                show_progress_with_dots "ZFS backup in progress" "$pid" 5
                wait "$pid"
            fi
            ;;
        "gzip")
            print_debug "Using gzip compression for ZFS backup"
            if command -v pv >/dev/null 2>&1; then
                zfs send -R "$SNAPSHOT_NAME" | pv -N "ZFS backup" | gzip | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file"
            else
                zfs send -R "$SNAPSHOT_NAME" | gzip | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file" &
                local pid=$!
                show_progress_with_dots "ZFS backup in progress" "$pid" 5
                wait "$pid"
            fi
            ;;
        "xz")
            print_debug "Using xz compression for ZFS backup"
            if command -v pv >/dev/null 2>&1; then
                zfs send -R "$SNAPSHOT_NAME" | pv -N "ZFS backup" | xz | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file"
            else
                zfs send -R "$SNAPSHOT_NAME" | xz | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file" &
                local pid=$!
                show_progress_with_dots "ZFS backup in progress" "$pid" 5
                wait "$pid"
            fi
            ;;
        "none")
            print_debug "No compression for ZFS backup"
            if command -v pv >/dev/null 2>&1; then
                zfs send -R "$SNAPSHOT_NAME" | pv -N "ZFS backup" | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file"
            else
                zfs send -R "$SNAPSHOT_NAME" | \
                gpg --cipher-algo "$ENCRYPTION_ALGO" --compress-algo 1 --symmetric --batch --yes --passphrase "$encryption_pass" \
                > "$backup_file" &
                local pid=$!
                show_progress_with_dots "ZFS backup in progress" "$pid" 5
                wait "$pid"
            fi
            ;;
        *)
            print_error "Unknown compression method: $COMPRESSION"
            return 1
            ;;
    esac

    # Check if backup succeeded
    local backup_result=$?

    if [ $backup_result -eq 0 ] && [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        # Quick verification - test GPG decryption
        if echo "$encryption_pass" | gpg --batch --yes --passphrase-fd 0 --decrypt "$backup_file" 2>/dev/null | head -c 1024 >/dev/null; then
            print_debug "ZFS backup completed and verified successfully"
            return 0
        else
            print_error "ZFS backup verification failed - backup may be corrupted"
            return 1
        fi
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
HYBRID BACKUP RESTORE INSTRUCTIONS
==================================
Date: $(date)
Files: $boot_backup_name.tar.gz.gpg ($boot_size)
       $zfs_backup_name.lz4.gpg ($zfs_size)
Pool: $ZFS_POOL | Method: $method | Duration: $duration

CRITICAL: You need the encryption password to restore!

RESTORE STEPS:
=============
1. Boot from Linux live USB and install tools:
   apt update && apt install -y zfsutils-linux gnupg gdisk lz4

2. Connect backup drive and identify target disk
   WARNING: Target disk will be COMPLETELY ERASED!

3. Create partitions on target disk (replace TARGET_DISK):
   sgdisk --zap-all /dev/TARGET_DISK
   sgdisk --new=1:0:+512M --typecode=1:ef00 /dev/TARGET_DISK
   sgdisk --new=2:0:0 --typecode=2:bf00 /dev/TARGET_DISK
   mkfs.fat -F32 /dev/TARGET_DISKp1

4. Restore ZFS pool:
   zpool create -f $ZFS_POOL /dev/TARGET_DISKp2
   gpg --decrypt $zfs_backup_name.lz4.gpg | lz4 -d | zfs receive -F $ZFS_POOL

5. Restore boot partition:
   mkdir /mnt/efi && mount /dev/TARGET_DISKp1 /mnt/efi
   gpg --decrypt $boot_backup_name.tar.gz.gpg | gunzip | tar -xf - -C /mnt/efi
   zpool set bootfs=$ZFS_POOL/ROOT/pve-1 $ZFS_POOL
   umount /mnt/efi

6. Reboot and remove live USB

VERIFY: System boots, zpool status shows ONLINE, all VMs present

Created by ZFS Backup System - $(date)
EOF

    print_debug "Restore instructions written to: $restore_file"
    return 0
}

