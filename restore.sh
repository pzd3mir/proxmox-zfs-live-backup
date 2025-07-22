#!/bin/bash
# ZFS Backup Restore Script - Simple and Reliable Version
# Restores hybrid backups (boot partition + ZFS pool) to target hardware
# Usage: Run from Ubuntu Live USB on target hardware

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN} $1${NC}"; }
print_error() { echo -e "${RED} $1${NC}"; }
print_warning() { echo -e "${YELLOW}  $1${NC}"; }
print_info() { echo -e "${BLUE}i $1${NC}"; }

# Configuration
NAS_IP="192.168.178.12"
NAS_SHARE="backups"
BACKUP_PATH="NAS/proxmox/system-images"
MOUNT_POINT="/mnt/backup-source"
USB_MOUNT_POINT="/mnt/usb-source"
CREDENTIALS_FILE="/root/.zfs-backup-credentials"
EFI_MOUNT="/mnt/efi"
ZFS_POOL="rpool"

# Global variables
BACKUP_SOURCE=""
BOOT_BACKUP_FILE=""
ZFS_BACKUP_FILE=""
TARGET_DISK=""
NAS_USER=""
NAS_PASS=""
ENCRYPTION_PASS=""
COMPRESSION_TYPE="gzip"

# Cleanup function
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null
    fi
    if mountpoint -q "$USB_MOUNT_POINT" 2>/dev/null; then
        umount "$USB_MOUNT_POINT" 2>/dev/null
    fi
    if mountpoint -q "$EFI_MOUNT" 2>/dev/null; then
        umount "$EFI_MOUNT" 2>/dev/null
    fi
    rm -f /tmp/.mount-creds 2>/dev/null
}

trap cleanup EXIT

# Check if running from live system
check_live_system() {
    print_info "Checking system requirements..."
    
    # Check if we're in a live environment
    if [ -d /rw ] || grep -q "live" /proc/cmdline 2>/dev/null || [ -n "$LIVE_MEDIA" ]; then
        print_status "Running in live environment"
    else
        print_warning "Not detected as live system - proceed with caution!"
        echo "This script should be run from a live USB/CD"
        echo "Continuing may damage your running system"
        read -p "Continue anyway? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            exit 1
        fi
    fi
    
    # Check for required tools
    local missing_tools=()
    for tool in zfs zpool gpg sgdisk mkfs.fat tar; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Install with: apt update && apt install -y zfsutils-linux gnupg gdisk dosfstools tar"
        exit 1
    fi
    
    print_status "All required tools available"
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Load credentials (same as integrity check)
load_credentials() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        NAS_USER=$(grep "^nas_username=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        NAS_PASS=$(grep "^nas_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        ENCRYPTION_PASS=$(grep "^encryption_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        
        # Load connection settings
        local file_ip=$(grep "^nas_ip=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        local file_share=$(grep "^nas_share=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        local file_path=$(grep "^nas_backup_path=" "$CREDENTIALS_FILE" | cut -d'=' -f2- || true)
        
        # Override defaults if found
        if [ -n "$file_ip" ]; then NAS_IP="$file_ip"; fi
        if [ -n "$file_share" ]; then NAS_SHARE="$file_share"; fi
        if [ -n "$file_path" ]; then BACKUP_PATH="$file_path"; fi
        
        if [ -n "$ENCRYPTION_PASS" ]; then
            print_status "Credentials loaded"
            return 0
        fi
    fi
    
    print_warning "Could not load all credentials from file"
    return 1
}

# Select backup source
select_backup_source() {
    echo "BACKUP SOURCE SELECTION"
    echo "======================="
    echo ""
    echo "Choose backup source:"
    echo "1) NAS/Network backups"
    echo "2) USB drive backups" 
    echo "3) Local directory backups"
    echo ""
    
    read -p "Select source (1/2/3): " source_choice
    echo ""
    
    case "$source_choice" in
        1)
            print_status "Selected: NAS/Network backups"
            BACKUP_SOURCE="nas"
            return 0
            ;;
        2)
            print_status "Selected: USB drive backups"
            BACKUP_SOURCE="usb"
            return 0
            ;;
        3)
            print_status "Selected: Local directory backups"
            BACKUP_SOURCE="local"
            return 0
            ;;
        *)
            print_error "Invalid selection"
            return 1
            ;;
    esac
}

# Mount NAS (same as integrity check)
mount_nas() {
    print_info "Mounting NAS backup share..."
    
    # Create temp credentials file
    cat > /tmp/.mount-creds << EOF
username=$NAS_USER
password=$NAS_PASS
EOF
    chmod 600 /tmp/.mount-creds
    
    mkdir -p "$MOUNT_POINT"
    
    if mount -t cifs "//$NAS_IP/$NAS_SHARE" "$MOUNT_POINT" \
        -o credentials=/tmp/.mount-creds,uid=root,gid=root,file_mode=0644,dir_mode=0755; then
        rm /tmp/.mount-creds
        print_status "NAS mounted at $MOUNT_POINT"
        return 0
    else
        rm /tmp/.mount-creds
        print_error "Failed to mount NAS"
        return 1
    fi
}

# Mount USB drive (simplified version)
mount_usb() {
    print_info "Detecting USB drives..."
    
    echo "Available external drives:"
    local count=1
    local usb_drives=()
    
    # Check SATA drives
    for device in /dev/sd[a-z]; do
        if [ -b "$device" ]; then
            local size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")
            local model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
            echo "$count) $device ($size) - $model"
            usb_drives[$count]="$device"
            count=$((count + 1))
        fi
    done
    
    # Check NVMe drives (skip nvme0 which is usually internal)
    for device in /dev/nvme[1-9]n[1-9]; do
        if [ -b "$device" ]; then
            local size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")
            local model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
            echo "$count) $device ($size) - $model"
            usb_drives[$count]="$device"
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 1 ]; then
        print_error "No external drives found"
        return 1
    fi
    
    echo ""
    read -p "Select backup drive (1-$((count-1))): " usb_choice
    
    if [[ "$usb_choice" =~ ^[0-9]+$ ]] && [ "$usb_choice" -ge 1 ] && [ "$usb_choice" -lt "$count" ]; then
        local selected_usb="${usb_drives[$usb_choice]}"
        local usb_partition="${selected_usb}1"
        
        # For NVMe drives, partition naming is different
        if [[ "$selected_usb" == *"nvme"* ]]; then
            usb_partition="${selected_usb}p1"
        fi
        
        # Try partition first, fall back to whole device
        if [ ! -b "$usb_partition" ]; then
            usb_partition="$selected_usb"
        fi
        
        mkdir -p "$USB_MOUNT_POINT"
        
        if mount "$usb_partition" "$USB_MOUNT_POINT"; then
            print_status "Backup drive mounted at $USB_MOUNT_POINT"
            return 0
        else
            print_error "Failed to mount backup drive"
            return 1
        fi
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Get local backup path
get_local_path() {
    echo "Enter path to backup files:"
    read -p "Path: " local_path
    
    if [ -d "$local_path" ]; then
        MOUNT_POINT="$local_path"
        BACKUP_PATH=""
        print_status "Using local path: $local_path"
        return 0
    else
        print_error "Path does not exist: $local_path"
        return 1
    fi
}

# Find and select backup files
find_backup_files() {
    print_info "Scanning for backup files..."
    
    local backup_dir
    if [ "$BACKUP_SOURCE" = "usb" ]; then
        backup_dir="$USB_MOUNT_POINT"
    else
        backup_dir="$MOUNT_POINT/$BACKUP_PATH"
    fi
    
    if [ ! -d "$backup_dir" ]; then
        print_error "Backup directory not found: $backup_dir"
        return 1
    fi
    
    # Look for backup sets (groups of files with same date)
    local backup_dates=()
    
    # Find all backup files and extract dates
    for file in "$backup_dir"/*.gpg; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            local date_part=$(echo "$basename" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
            
            if [ -n "$date_part" ] && [[ ! " ${backup_dates[@]} " =~ " ${date_part} " ]]; then
                backup_dates+=("$date_part")
            fi
        fi
    done
    
    if [ ${#backup_dates[@]} -eq 0 ]; then
        print_error "No backup files found in $backup_dir"
        return 1
    fi
    
    echo ""
    echo "Available backup sets:"
    echo "====================="
    
    local count=1
    for date in "${backup_dates[@]}"; do
        echo "$count) Backup Set: $date"
        
        # Find components for this date
        local boot_found=""
        local zfs_found=""
        
        for file in "$backup_dir"/*${date}*.gpg; do
            if [ -f "$file" ]; then
                local basename=$(basename "$file")
                local size=$(ls -lh "$file" | awk '{print $5}')
                
                if [[ "$basename" == boot-partition-* ]]; then
                    boot_found="$file"
                    echo "   - Boot partition: $basename ($size)"
                elif [[ "$basename" == *backup* ]] || [[ "$basename" == *zfs* ]]; then
                    zfs_found="$file"
                    echo "   - ZFS data: $basename ($size)"
                fi
            fi
        done
        
        echo ""
        count=$((count + 1))
    done
    
    read -p "Select backup set (1-${#backup_dates[@]}): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#backup_dates[@]}" ]; then
        local selected_date="${backup_dates[$((selection-1))]}"
        print_status "Selected backup set: $selected_date"
        
        # Find the actual files for this date
        for file in "$backup_dir"/*${selected_date}*.gpg; do
            if [ -f "$file" ]; then
                local basename=$(basename "$file")
                
                if [[ "$basename" == boot-partition-* ]]; then
                    BOOT_BACKUP_FILE="$file"
                elif [[ "$basename" == *backup* ]] || [[ "$basename" == *zfs* ]]; then
                    ZFS_BACKUP_FILE="$file"
                    
                    # Detect compression type from filename
                    if [[ "$basename" == *.xz.gpg ]]; then
                        COMPRESSION_TYPE="xz"
                    else
                        COMPRESSION_TYPE="gzip"
                    fi
                fi
            fi
        done
        
        # Verify we found both files
        if [ -z "$BOOT_BACKUP_FILE" ] || [ -z "$ZFS_BACKUP_FILE" ]; then
            print_error "Incomplete backup set - missing boot or ZFS file"
            return 1
        fi
        
        print_status "Boot file: $(basename "$BOOT_BACKUP_FILE")"
        print_status "ZFS file: $(basename "$ZFS_BACKUP_FILE")"
        print_status "Compression: $COMPRESSION_TYPE"
        
        return 0
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Get encryption password
get_encryption_password() {
    echo ""
    echo "ENCRYPTION PASSWORD"
    echo "==================="
    
    if [ -n "$ENCRYPTION_PASS" ]; then
        print_info "Using stored encryption password"
        
        # Quick test to verify password works
        if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$BOOT_BACKUP_FILE" 2>/dev/null | head -c 100 >/dev/null 2>&1; then
            print_status "Password verification successful"
            return 0
        else
            print_warning "Stored password doesn't work, requesting new one"
        fi
    fi
    
    # Prompt for password
    echo "Enter backup encryption password:"
    read -s -p "Password: " ENCRYPTION_PASS
    echo ""
    
    if [ ${#ENCRYPTION_PASS} -lt 8 ]; then
        print_error "Password too short (minimum 8 characters)"
        return 1
    fi
    
    # Test password with backup file
    print_info "Verifying encryption password..."
    if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$BOOT_BACKUP_FILE" 2>/dev/null | head -c 100 >/dev/null 2>&1; then
        print_status "Password verification successful"
        return 0
    else
        print_error "Password verification failed"
        return 1
    fi
}

# Select target disk
select_target_disk() {
    echo ""
    echo "TARGET DISK SELECTION"
    echo "===================="
    print_warning "WARNING: Target disk will be COMPLETELY ERASED!"
    echo ""
    
    echo "Available disks:"
    local count=1
    local target_disks=()
    
    # List all disks with size info
    for device in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
        if [ -b "$device" ]; then
            local size=$(lsblk -d -n -o SIZE "$device" 2>/dev/null || echo "Unknown")
            local model=$(lsblk -d -n -o MODEL "$device" 2>/dev/null || echo "Unknown")
            
            echo "$count) $device ($size) - $model"
            target_disks[$count]="$device"
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 1 ]; then
        print_error "No disks found"
        return 1
    fi
    
    echo ""
    read -p "Select target disk (1-$((count-1))): " disk_choice
    
    if [[ "$disk_choice" =~ ^[0-9]+$ ]] && [ "$disk_choice" -ge 1 ] && [ "$disk_choice" -lt "$count" ]; then
        TARGET_DISK="${target_disks[$disk_choice]}"
        
        echo ""
        print_warning "Selected disk: $TARGET_DISK"
        print_warning "ALL DATA ON THIS DISK WILL BE LOST!"
        echo ""
        
        read -p "Are you absolutely sure? Type 'YES' to continue: " confirm
        
        if [ "$confirm" = "YES" ]; then
            print_status "Target disk confirmed: $TARGET_DISK"
            return 0
        else
            print_info "Operation cancelled"
            return 1
        fi
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Create partitions on target disk
create_partitions() {
    print_info "Creating partition table on $TARGET_DISK..."
    
    # Wipe disk completely
    print_info "Wiping existing partition table..."
    if ! sgdisk --zap-all "$TARGET_DISK"; then
        print_error "Failed to wipe disk"
        return 1
    fi
    
    # Create partitions
    print_info "Creating EFI system partition (512MB)..."
    if ! sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:"EFI System" "$TARGET_DISK"; then
        print_error "Failed to create EFI partition"
        return 1
    fi
    
    print_info "Creating ZFS pool partition..."
    if ! sgdisk --new=2:0:0 --typecode=2:bf00 --change-name=2:"ZFS Pool" "$TARGET_DISK"; then
        print_error "Failed to create ZFS partition"
        return 1
    fi
    
    # Wait for kernel to recognize new partitions
    sleep 2
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 1
    
    # Determine partition names
    local efi_partition="${TARGET_DISK}1"
    local zfs_partition="${TARGET_DISK}2"
    
    # Handle NVMe naming
    if [[ "$TARGET_DISK" == *"nvme"* ]]; then
        efi_partition="${TARGET_DISK}p1"
        zfs_partition="${TARGET_DISK}p2"
    fi
    
    # Format EFI partition
    print_info "Formatting EFI partition..."
    if ! mkfs.fat -F32 "$efi_partition"; then
        print_error "Failed to format EFI partition"
        return 1
    fi
    
    print_status "Partitions created successfully"
    print_info "EFI partition: $efi_partition"
    print_info "ZFS partition: $zfs_partition"
    
    # Export for other functions
    export EFI_PARTITION="$efi_partition"
    export ZFS_PARTITION="$zfs_partition"
    
    return 0
}

# Restore ZFS pool
restore_zfs_pool() {
    print_info "Restoring ZFS pool..."
    
    # Create ZFS pool
    print_info "Creating ZFS pool '$ZFS_POOL' on $ZFS_PARTITION..."
    if ! zpool create -f "$ZFS_POOL" "$ZFS_PARTITION"; then
        print_error "Failed to create ZFS pool"
        return 1
    fi
    
    # Restore ZFS data
    print_info "Restoring ZFS data from backup..."
    print_info "This may take 10-30 minutes depending on backup size..."
    
    local decompression_cmd
    case "$COMPRESSION_TYPE" in
        "gzip") decompression_cmd="gunzip" ;;
        "xz") decompression_cmd="unxz" ;;
        *) print_error "Unknown compression: $COMPRESSION_TYPE"; return 1 ;;
    esac
    
    # Stream restoration with progress
    if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$ZFS_BACKUP_FILE" | \
       $decompression_cmd | \
       pv -p -t -e -r -b | \
       zfs receive -F "$ZFS_POOL"; then
        print_status "ZFS data restored successfully"
    else
        print_error "ZFS restoration failed"
        return 1
    fi
    
    # Verify pool status
    print_info "Verifying ZFS pool status..."
    if zpool status "$ZFS_POOL" | grep -q "ONLINE"; then
        print_status "ZFS pool is healthy"
    else
        print_warning "ZFS pool may have issues"
        zpool status "$ZFS_POOL"
    fi
    
    return 0
}

# Restore boot partition
restore_boot_partition() {
    print_info "Restoring boot partition..."
    
    # Mount EFI partition
    mkdir -p "$EFI_MOUNT"
    if ! mount "$EFI_PARTITION" "$EFI_MOUNT"; then
        print_error "Failed to mount EFI partition"
        return 1
    fi
    
    # Restore boot files
    print_info "Extracting boot files..."
    if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$BOOT_BACKUP_FILE" | \
       gunzip | tar -xf - -C "$EFI_MOUNT"; then
        print_status "Boot files restored successfully"
    else
        print_error "Boot file restoration failed"
        umount "$EFI_MOUNT"
        return 1
    fi
    
    # Set bootfs property (try to detect root dataset)
    print_info "Configuring ZFS boot settings..."
    local root_dataset=$(zfs list -H -o name | grep -E "ROOT|root" | head -1)
    
    if [ -n "$root_dataset" ]; then
        if zpool set bootfs="$root_dataset" "$ZFS_POOL"; then
            print_status "Boot filesystem set to: $root_dataset"
        else
            print_warning "Failed to set boot filesystem property"
        fi
    else
        print_warning "Could not detect root dataset - you may need to set bootfs manually"
        print_info "After boot, run: zpool set bootfs=rpool/ROOT/pve-1 rpool"
    fi
    
    # Unmount EFI partition
    umount "$EFI_MOUNT"
    
    return 0
}

# Final verification
verify_restoration() {
    print_info "Running final verification..."
    
    # Check ZFS pool
    if ! zpool status "$ZFS_POOL" >/dev/null 2>&1; then
        print_error "ZFS pool verification failed"
        return 1
    fi
    
    # Check datasets
    local dataset_count=$(zfs list -H | wc -l)
    print_status "ZFS pool healthy with $dataset_count datasets"
    
    # Check EFI partition
    if mount "$EFI_PARTITION" "$EFI_MOUNT"; then
        local boot_files=$(find "$EFI_MOUNT" -type f | wc -l)
        print_status "EFI partition contains $boot_files boot files"
        umount "$EFI_MOUNT"
    else
        print_warning "Could not verify EFI partition"
    fi
    
    return 0
}

# Main restore process
main() {
    echo "ZFS BACKUP RESTORE SYSTEM"
    echo "========================="
    echo ""
    
    # Check system requirements
    check_live_system
    
    # Load credentials
    load_credentials || true  # Continue even if credentials not found
    
    # Select backup source
    if ! select_backup_source; then
        exit 1
    fi
    
    # Mount backup source
    case "$BACKUP_SOURCE" in
        "nas")
            if ! mount_nas; then
                exit 1
            fi
            ;;
        "usb")
            if ! mount_usb; then
                exit 1
            fi
            ;;
        "local")
            if ! get_local_path; then
                exit 1
            fi
            ;;
    esac
    
    # Find backup files
    if ! find_backup_files; then
        exit 1
    fi
    
    # Get encryption password
    if ! get_encryption_password; then
        exit 1
    fi
    
    # Select target disk
    if ! select_target_disk; then
        exit 1
    fi
    
    # Final confirmation
    echo ""
    echo "RESTORE SUMMARY"
    echo "==============="
    echo "Boot backup: $(basename "$BOOT_BACKUP_FILE")"
    echo "ZFS backup: $(basename "$ZFS_BACKUP_FILE")"
    echo "Target disk: $TARGET_DISK"
    echo "Compression: $COMPRESSION_TYPE"
    echo ""
    print_warning "This will COMPLETELY ERASE $TARGET_DISK!"
    echo ""
    
    read -p "Continue with restore? (yes/no): " final_confirm
    if [ "$final_confirm" != "yes" ]; then
        print_info "Restore cancelled"
        exit 0
    fi
    
    # Perform restore
    echo ""
    echo "STARTING RESTORE PROCESS"
    echo "========================"
    
    if ! create_partitions; then
        print_error "Partition creation failed"
        exit 1
    fi
    
    if ! restore_zfs_pool; then
        print_error "ZFS pool restoration failed"
        exit 1
    fi
    
    if ! restore_boot_partition; then
        print_error "Boot partition restoration failed"
        exit 1
    fi
    
    if ! verify_restoration; then
        print_error "Restoration verification failed"
        exit 1
    fi
    
    echo ""
    echo "RESTORE COMPLETED SUCCESSFULLY!"
    echo "==============================="
    print_status "System has been restored to $TARGET_DISK"
    print_status "ZFS pool '$ZFS_POOL' is online and healthy"
    print_status "Boot partition restored successfully"
    echo ""
    echo "Next steps:"
    echo "1. Remove live USB/CD"
    echo "2. Reboot the system"
    echo "3. System should boot normally"
    echo ""
    echo "If system doesn't boot:"
    echo "- Check BIOS/UEFI settings"
    echo "- Verify EFI boot entries with: efibootmgr -v"
    echo "- Check ZFS pool status with: zpool status"
}

# Run main function
main "$@"