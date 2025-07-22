#!/bin/bash
# System Detection Library - ZFS Backup System
# Handles complex device detection for EFI/boot partitions and ZFS pools
# Supports both NVMe and SATA device naming conventions

# Detect system disk and EFI partition
detect_system_components() {
    
    local efi_partition=""
    local system_disk=""

    # Method 1: Check /boot/efi mount
    if mountpoint -q /boot/efi 2>/dev/null; then
        efi_partition=$(df /boot/efi | tail -1 | awk '{print $1}')

        # Extract system disk from EFI partition
        system_disk=$(echo "$efi_partition" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
    fi

    # Method 2: Find from ZFS pool if EFI method failed
    if [ -z "$system_disk" ]; then
        local zfs_device=$(zpool status "$ZFS_POOL" 2>/dev/null | grep -E 'nvme|sd|vd' | head -1 | awk '{print $1}')

        if [[ "$zfs_device" == *"part"* ]]; then
            # Handle complex partition names like nvme-eui.xxx-part3
            local base_device=$(echo "$zfs_device" | sed 's/-part[0-9]*$//')

            # Find the actual /dev/ path via symlinks
            system_disk=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep "$base_device" | grep -v "part" | awk '{print $NF}' | sed 's|.*/||' | head -1)
            if [ -n "$system_disk" ]; then
                system_disk="/dev/$system_disk"

                # Find EFI partition (usually partition 1 or 2)
                for part_num in 1 2; do
                    local test_part="${system_disk}p${part_num}"
                    if [ -b "$test_part" ]; then
                        local fstype=$(blkid -o value -s TYPE "$test_part" 2>/dev/null || echo "")
                        if [[ "$fstype" == "vfat" ]]; then
                            efi_partition="$test_part"
                            break
                        fi
                    fi
                done
            fi
        else
            # Handle regular device names
            if [[ "$zfs_device" == /dev/* ]]; then
                system_disk=$(echo "$zfs_device" | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
            fi
        fi
    fi

    # Method 3: Manual detection if still not found
    if [ -z "$system_disk" ] || [ -z "$efi_partition" ]; then
        echo "MANUAL SYSTEM DETECTION REQUIRED"
        echo "=================================="
        print_warning "Could not automatically detect system components"
        echo ""
        print_info "Available disks and partitions:"
        lsblk -f 2>/dev/null | grep -E "nvme|sd|vd" || echo "No standard storage devices found"
        echo ""
        print_info "ZFS pool devices:"
        zpool status "$ZFS_POOL" 2>/dev/null | grep -E "nvme|sd|vd" || echo "No devices found in pool"
        echo ""
        print_info "Current mounts:"
        df 2>/dev/null | grep -E "/boot|/dev/(nvme|sd|vd)" || echo "No relevant mounts found"
        echo ""

        read -p "Enter system disk (e.g., /dev/nvme0n1): " manual_disk
        read -p "Enter EFI partition (e.g., /dev/nvme0n1p2): " manual_efi

        if [ -b "$manual_disk" ] && [ -b "$manual_efi" ]; then
            system_disk="$manual_disk"
            efi_partition="$manual_efi"
            print_status "Using manually specified components"
        else
            print_error "Invalid components specified"
            return 1
        fi
    fi

    # Verify detected components
    if [ ! -b "$system_disk" ]; then
        print_error "System disk not found or not a block device: $system_disk"
        return 1
    fi

    if [ ! -b "$efi_partition" ]; then
        print_error "EFI partition not found or not a block device: $efi_partition"
        return 1
    fi

    # Additional validation
    local efi_fstype=$(blkid -o value -s TYPE "$efi_partition" 2>/dev/null || echo "unknown")
    if [[ "$efi_fstype" != "vfat" ]]; then
        print_warning "EFI partition does not appear to be FAT32 (found: $efi_fstype)"
    fi

    print_status " System disk detected: $system_disk"
    print_status " EFI partition detected: $efi_partition ($efi_fstype)"

    # Export global variables for other modules
    export SYSTEM_DISK="$system_disk"
    export EFI_PARTITION="$efi_partition"

    return 0
}

# Check if boot partition is safe to backup (not actively in use)
check_boot_partition_safety() {

    # Check if any processes are using the EFI partition
    if lsof "$EFI_PARTITION" 2>/dev/null | grep -q .; then
        print_warning "�  EFI partition has active file handles"
        print_info "This is usually safe during backup, continuing..."
        return 0
    fi

    # Check if partition is mounted read-write
    if mount | grep "$EFI_PARTITION" | grep -q rw; then
        return 0
    fi

    return 0
}


# Create backup snapshot with proper naming and error handling
create_backup_snapshot() {
    echo "SNAPSHOT CREATION"
    echo "================="
    print_info "Creating ZFS snapshot for consistent backup..."

    local date=$(date +%Y%m%d-%H%M)
    SNAPSHOT_NAME="$ZFS_POOL@backup-$date"

    # Check if snapshot already exists (from failed previous run)
    if zfs list "$SNAPSHOT_NAME" >/dev/null 2>&1; then
        print_warning "�  Snapshot already exists: $SNAPSHOT_NAME"
        print_info "This might be from a previous failed backup"
        
        if [ "$AUTO_MODE" = false ]; then
            read -p "Reuse existing snapshot? (y/N): " reuse_choice
            if [[ "$reuse_choice" == [Yy]* ]]; then
                print_status " Reusing existing snapshot: $SNAPSHOT_NAME"
                export SNAPSHOT_NAME
                return 0
            else
                print_info "Destroying old snapshot and creating new one..."
                if ! zfs destroy -r "$SNAPSHOT_NAME" 2>/dev/null; then
                    print_error "Failed to remove old snapshot: $SNAPSHOT_NAME"
                    return 1
                fi
            fi
        else
            print_status " Auto-mode: Reusing existing snapshot: $SNAPSHOT_NAME"
            export SNAPSHOT_NAME
            return 0
        fi
    fi

    # Create new snapshot
    if ! zfs snapshot -r "$SNAPSHOT_NAME" 2>/dev/null; then
        print_error "[ERROR] Failed to create ZFS snapshot"
        echo ""
        print_info "💡 Possible causes:"
        echo "• Insufficient pool space"
        echo "• Pool is read-only or busy"
        echo "• Permission issues (try running as root)"
        echo "• Dataset is currently being backed up"
        echo ""
        print_info "Pool status:"
        zpool status "$ZFS_POOL" 2>/dev/null || echo "Cannot retrieve pool status"
        return 1
    fi

    print_status " Snapshot created: $SNAPSHOT_NAME"
    
    # Get snapshot size for progress estimation
    local snap_size=$(zfs list -H -p -o used "$SNAPSHOT_NAME" 2>/dev/null || echo "0")
    if [ "$snap_size" -gt 0 ]; then
        local snap_size_gb=$((snap_size / 1024 / 1024 / 1024))
        local snap_size_mb=$((snap_size / 1024 / 1024))
        if [ "$snap_size_gb" -gt 0 ]; then
            print_info "=� Snapshot size: ${snap_size_gb}GB"
        else
            print_info "=� Snapshot size: ${snap_size_mb}MB"
        fi
    fi

    export SNAPSHOT_NAME
    return 0
}


# Get device partition naming (handles NVMe vs SATA differences)
get_partition_name() {
    local device="$1"
    local part_num="$2"
    
    if [[ "$device" == *"nvme"* ]]; then
        echo "${device}p${part_num}"
    else
        echo "${device}${part_num}"
    fi
}

# Detect filesystem type of a device
detect_filesystem_type() {
    local device="$1"
    
    if [ ! -b "$device" ]; then
        echo "unknown"
        return 1
    fi
    
    local fstype=$(blkid -o value -s TYPE "$device" 2>/dev/null || echo "")
    if [ -z "$fstype" ]; then
        # Try alternative detection
        fstype=$(file -sL "$device" 2>/dev/null | grep -o '\w*\s*filesystem' | awk '{print $1}' | head -1 | tr '[:upper:]' '[:lower:]')
    fi
    
    echo "${fstype:-unknown}"
}