#!/bin/bash
# USB Functions Library - ZFS Backup System
# Handles USB drive detection, mounting, and backup operations
# Supports multiple filesystem types (ext4, NTFS, exFAT, FAT32)

# Global USB mount point
USB_MOUNT_POINT="/mnt/usb-backup-auto"

# List available USB drives for backup selection
list_usb_drives() {
    echo "USB DRIVE DETECTION"
    echo "==================="
    print_info "Scanning for external USB drives..."

    # Get system root device to exclude it (works with ZFS)
    local root_device=""
    if command -v zpool >/dev/null 2>&1; then
        # For ZFS systems, get the actual device from zpool status
        root_device=$(zpool status rpool 2>/dev/null | grep -E "nvme|sd" | head -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||' || echo "")
    fi
    # Fallback to traditional method if ZFS detection fails
    if [ -z "$root_device" ]; then
        root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
    fi

    local drive_names=()
    local count=1

    print_info "Available external drives:"
    echo "============================="

    # Look for potential external drives (exclude root device)
    for device in /dev/sd[a-z] /dev/nvme[1-9]n[1-9]; do
        if [ -b "$device" ]; then
            local device_name=$(basename "$device")
            
            # Skip if this is the root device
            if [ "$device_name" = "$root_device" ]; then
                continue
            fi

            # Get device information
            local size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")
            local model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
            local fstype=$(lsblk -n -o FSTYPE "${device}1" 2>/dev/null | head -1 | tr -d '\n' || echo "Unknown")
            
            # Check if mounted
            local mount_point=$(df 2>/dev/null | grep "$device" | awk '{print $6}' | head -1 || true)
            if [ -n "$mount_point" ]; then
                echo "$count) $device ($size $fstype) - $model [Mounted at $mount_point]"
            else
                echo "$count) $device ($size $fstype) - $model [Available]"
            fi

            drive_names[$count]="$device"
            count=$((count + 1))
        fi
    done

    if [ $count -eq 1 ]; then
        print_error "No external drives found"
        echo ""
        print_info "Available storage devices:"
        lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -E "sd[a-z]|nvme" || echo "No storage devices found"
        return 1
    fi

    echo ""

    # Get user selection with timeout
    if [ "$AUTO_MODE" = true ]; then
        print_error "Auto mode requires pre-selected USB device"
        return 1
    fi

    print_info "Selection timeout: ${USER_TIMEOUT}s"
    local max_choice=$((count-1))
    local prompt="Select drive (1-${max_choice}) or 'q' to quit: "
    
    local selection=""
    if read -t "$USER_TIMEOUT" -p "$prompt" selection; then
        echo ""
        if [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
            print_info "USB backup cancelled by user"
            return 1
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$count" ]; then
            export SELECTED_TARGET="${drive_names[$selection]}"
            print_status "[OK] Selected USB drive: $SELECTED_TARGET"
            return 0
        else
            print_error "Invalid selection: '$selection' (valid range: 1-$((count-1)))"
            return 1
        fi
    else
        echo ""
        print_error "Selection timeout - no drive selected"
        return 1
    fi
}

# Mount USB device with automatic filesystem detection
mount_usb_device() {
    local usb_device="$1"
    
    if [ -z "$usb_device" ]; then
        print_error "No USB device specified for mounting"
        return 1
    fi


    # Detect partition scheme and get the right partition
    local usb_partition=""
    if ! detect_usb_partition "$usb_device" usb_partition; then
        print_error "Failed to detect USB partition"
        return 1
    fi

    # Create mount point
    mkdir -p "$USB_MOUNT_POINT"
    if [ ! -d "$USB_MOUNT_POINT" ]; then
        print_error "Failed to create USB mount point: $USB_MOUNT_POINT"
        return 1
    fi

    # Try mounting with different filesystem types
    
    if mount_usb_partition_auto "$usb_partition" "$USB_MOUNT_POINT"; then
        print_status "USB device mounted successfully"
        
        # Test write permissions
        if touch "$USB_MOUNT_POINT/.write-test-$$" 2>/dev/null; then
            rm -f "$USB_MOUNT_POINT/.write-test-$$"
            return 0
        else
            print_error "USB device mounted but no write permissions"
            umount "$USB_MOUNT_POINT" 2>/dev/null
            return 1
        fi
    else
        print_error "Failed to mount USB device"
        return 1
    fi
}

# Detect USB partition (handles NVMe vs SATA naming)
detect_usb_partition() {
    local usb_device="$1"
    local -n partition_var="$2"
    

    # For NVMe drives, partition naming is different
    if [[ "$usb_device" == *"nvme"* ]]; then
        partition_var="${usb_device}p1"
    else
        partition_var="${usb_device}1"
    fi

    # Check if partition exists, fall back to whole device
    if [ ! -b "$partition_var" ]; then
        partition_var="$usb_device"
    fi

    # Verify the selected partition/device is actually a block device
    if [ ! -b "$partition_var" ]; then
        print_error "Selected device $partition_var is not a valid block device"
        return 1
    fi

    return 0
}

# Mount USB partition with automatic filesystem detection
mount_usb_partition_auto() {
    local partition="$1"
    local mount_point="$2"
    
    # Try mounting with auto-detection first
    if mount "$partition" "$mount_point" 2>/dev/null; then
        return 0
    fi

    # Try specific filesystem types
    local filesystems=("ext4" "ntfs" "exfat" "vfat" "ext3" "ext2")
    
    for fs in "${filesystems[@]}"; do
        if mount -t "$fs" "$partition" "$mount_point" 2>/dev/null; then
            return 0
        fi
    done

    print_error "Failed to mount USB drive with any filesystem type"
    return 1
}

# Unmount USB device safely
unmount_usb_device() {
    local mount_point="${1:-$USB_MOUNT_POINT}"
    
    if [ ! -d "$mount_point" ]; then
        return 0
    fi

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        return 0
    fi

    
    # Sync before unmounting
    sync 2>/dev/null || true
    
    # Try gentle unmount first
    if umount "$mount_point" 2>/dev/null; then
        rmdir "$mount_point" 2>/dev/null || true
        return 0
    fi

    print_error "Failed to unmount USB device: $mount_point"
    return 1
}

# Check USB storage space and requirements
check_usb_space_requirements() {
    local mount_point="${1:-$USB_MOUNT_POINT}"
    local required_gb="${2:-15}"  # Default 15GB requirement
    
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        print_error "USB device not mounted at: $mount_point"
        return 1
    fi

    # Get available space
    local available_bytes=$(df -B1 "$mount_point" | tail -1 | awk '{print $4}')
    local available_gb=$((available_bytes / 1024 / 1024 / 1024))
    

    if [ "$available_gb" -lt "$required_gb" ]; then
        print_error "Insufficient space on USB"
        print_info "Required: ${required_gb}GB"
        print_info "Available: ${available_gb}GB"
        return 1
    fi

    print_status "USB space available: ${available_gb}GB"
    return 0
}

# Validate USB device before backup operations
validate_usb_device() {
    local usb_device="$1"
    
    if [ -z "$usb_device" ]; then
        print_error "No USB device specified for validation"
        return 1
    fi


    # Check if device exists
    if [ ! -b "$usb_device" ]; then
        print_error "USB device does not exist: $usb_device"
        return 1
    fi

    return 0
}

# Cleanup USB operations
cleanup_usb_operations() {
    
    # Unmount USB devices
    unmount_usb_device "$USB_MOUNT_POINT" 2>/dev/null || true
    
    # Clean up any test files
    rm -f "$USB_MOUNT_POINT/.write-test-"* 2>/dev/null || true
    
}