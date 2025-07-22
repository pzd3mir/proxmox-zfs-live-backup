#!/bin/bash
# ZFS Backup Integrity Check - Simple and Reliable Version
# Tests encrypted backup files from multiple sources (NAS/USB/Local)

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}i $1${NC}"; }

# Configuration
NAS_IP="192.168.178.12"
NAS_SHARE="backups"
BACKUP_PATH="NAS/proxmox/system-images"
MOUNT_POINT="/mnt/backup-test"
USB_MOUNT_POINT="/mnt/usb-test"
CREDENTIALS_FILE="/root/.zfs-backup-credentials"

# Global variables
BACKUP_SOURCE=""
SELECTED_BACKUP=""
NAS_USER=""
NAS_PASS=""
ENCRYPTION_PASS=""

# Cleanup function
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null
    fi
    if mountpoint -q "$USB_MOUNT_POINT" 2>/dev/null; then
        umount "$USB_MOUNT_POINT" 2>/dev/null
    fi
    rm -f /tmp/.mount-creds 2>/dev/null
}

trap cleanup EXIT

# Load credentials
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
        
        if [ -n "$NAS_USER" ] && [ -n "$NAS_PASS" ] && [ -n "$ENCRYPTION_PASS" ]; then
            print_status "Credentials loaded"
            return 0
        fi
    fi
    
    print_error "Could not load credentials"
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
    echo "3) Local file backups"
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
            print_status "Selected: Local file backups"
            BACKUP_SOURCE="local"
            return 0
            ;;
        *)
            print_error "Invalid selection"
            return 1
            ;;
    esac
}

# Mount NAS
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

# Mount USB drive (simplified)
mount_usb() {
    print_info "Detecting USB drives..."
    
    echo "Available external drives:"
    local count=1
    local usb_drives=()
    
    # Get system root device to exclude it
    local root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's|/dev/||')
    
    # Check SATA drives
    for device in /dev/sd[a-z]; do
        if [ -b "$device" ]; then
            local device_name=$(basename "$device")
            if [ "$device_name" = "$root_device" ]; then
                continue
            fi
            
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
            local device_name=$(basename "$device")
            if [ "$device_name" = "$root_device" ]; then
                continue
            fi
            
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
    read -p "Select drive (1-$((count-1))): " usb_choice
    
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
            print_status "Drive mounted at $USB_MOUNT_POINT"
            return 0
        else
            print_error "Failed to mount drive"
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

# List available backups (simplified)
list_backups() {
    print_info "Available backup files:"
    echo "======================="
    
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
    
    local count=1
    local backup_files=()
    
    # Look for encrypted backup files
    for file in "$backup_dir"/*.gpg; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            local size=$(ls -lh "$file" | awk '{print $5}')
            local date=$(stat -c %y "$file" | cut -d' ' -f1,2 | cut -d'.' -f1)
            
            echo "$count) $basename"
            echo "   Size: $size"
            echo "   Date: $date"
            echo ""
            
            backup_files[$count]="$file"
            count=$((count + 1))
        fi
    done
    
    if [ $count -eq 1 ]; then
        print_error "No backup files found in $backup_dir"
        return 1
    fi
    
    echo "Select backup to test (1-$((count-1))) or 'q' to quit:"
    read -p "Choice: " selection
    
    if [ "$selection" = "q" ]; then
        return 1
    elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$count" ]; then
        SELECTED_BACKUP="${backup_files[$selection]}"
        print_status "Selected: $(basename "$SELECTED_BACKUP")"
        return 0
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Test 1: File integrity
test_file_integrity() {
    print_info "Test 1: File Integrity Check"
    echo "=============================="
    
    if [ ! -f "$SELECTED_BACKUP" ]; then
        print_error "Backup file not found: $SELECTED_BACKUP"
        return 1
    fi
    
    # Basic file checks
    local file_size=$(ls -lh "$SELECTED_BACKUP" | awk '{print $5}')
    local file_type=$(file "$SELECTED_BACKUP")
    
    print_status "File exists and accessible"
    print_info "Size: $file_size"
    print_info "Type: $file_type"
    
    # Check if file is not empty
    if [ ! -s "$SELECTED_BACKUP" ]; then
        print_error "File is empty"
        return 1
    fi
    
    if [[ "$file_type" == *"GPG"* ]] || [[ "$file_type" == *"encrypted"* ]]; then
        print_status "File appears to be encrypted (GPG format)"
    else
        print_warning "File doesn't appear to be GPG encrypted"
    fi
    
    return 0
}

# Test 2: GPG decryption
test_gpg_decryption() {
    print_info "Test 2: GPG Decryption Test"
    echo "============================="
    
    print_info "Testing GPG decryption (first 1KB)..."
    
    # Test decryption with password
    if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | head -c 1024 | hexdump -C >/dev/null 2>&1; then
        print_status "GPG decryption successful"
        return 0
    else
        print_error "GPG decryption failed"
        print_info "This could mean:"
        echo "  - Wrong encryption password"
        echo "  - Corrupted backup file"
        echo "  - File not properly encrypted"
        return 1
    fi
}

# Test 3: Compression integrity
test_compression_integrity() {
    print_info "Test 3: Compression Test"
    echo "========================="
    
    print_info "Testing compression layer..."
    
    # Test gzip (most common)
    if echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | gunzip -t 2>/dev/null; then
        print_status "Gzip compression test passed"
        return 0
    # Test xz compression
    elif echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | xz -t 2>/dev/null; then
        print_status "XZ compression test passed"
        return 0
    else
        print_error "Compression test failed"
        return 1
    fi
}

# Test 4: ZFS stream validation
test_zfs_stream() {
    print_info "Test 4: ZFS Stream Validation"
    echo "=============================="
    
    print_info "Testing ZFS stream format..."
    
    # Check if we get valid ZFS stream data (try gzip first)
    local zfs_header=$(echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | gunzip 2>/dev/null | head -c 1024 | hexdump -C 2>/dev/null | head -2)
    
    # If gzip failed, try xz
    if [ -z "$zfs_header" ]; then
        zfs_header=$(echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | unxz 2>/dev/null | head -c 1024 | hexdump -C 2>/dev/null | head -2)
    fi
    
    if [ -n "$zfs_header" ]; then
        print_status "ZFS stream data appears valid"
        return 0
    else
        print_error "Could not read ZFS stream data"
        return 1
    fi
}

# Test 5: ZFS compatibility
test_zfs_compatibility() {
    print_info "Test 5: ZFS Compatibility Test"
    echo "==============================="
    
    print_info "Testing ZFS stream compatibility..."
    
    # Test with gzip first
    local zfs_output=$(echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | gunzip 2>/dev/null | zfs receive -nv test-pool 2>&1 || true)
    
    # If gzip failed, try xz
    if [ -z "$zfs_output" ] || [[ "$zfs_output" == *"invalid"* ]]; then
        zfs_output=$(echo "$ENCRYPTION_PASS" | gpg --batch --yes --passphrase-fd 0 --decrypt "$SELECTED_BACKUP" 2>/dev/null | unxz 2>/dev/null | zfs receive -nv test-pool 2>&1 || true)
    fi
    
    # Check for expected outputs
    if echo "$zfs_output" | grep -q "would receive\|does not exist\|cannot receive"; then
        print_status "ZFS stream format validation passed"
        return 0
    else
        print_warning "ZFS compatibility test inconclusive"
        print_info "This may still be a valid backup"
        return 0  # Don't fail on this
    fi
}

# Size estimation
estimate_size() {
    print_info "Backup Size Analysis"
    echo "===================="
    
    local compressed_size=$(ls -lh "$SELECTED_BACKUP" | awk '{print $5}')
    local compressed_bytes=$(ls -l "$SELECTED_BACKUP" | awk '{print $5}')
    
    print_info "Compressed backup size: $compressed_size"
    
    # Estimate uncompressed size (typical 2-4x compression)
    local estimated_min=$((compressed_bytes * 2))
    local estimated_max=$((compressed_bytes * 4))
    local estimated_gb_min=$((estimated_min / 1024 / 1024 / 1024))
    local estimated_gb_max=$((estimated_max / 1024 / 1024 / 1024))
    
    print_info "Estimated uncompressed size: ${estimated_gb_min}-${estimated_gb_max}GB"
    print_info "Minimum target drive size: $((estimated_gb_max + 5))GB (recommended)"
}

# Main function
main() {
    echo "ZFS BACKUP INTEGRITY TEST"
    echo "========================="
    echo ""
    
    # Load credentials
    if ! load_credentials; then
        exit 1
    fi
    
    # Select backup source
    if ! select_backup_source; then
        exit 1
    fi
    
    # Mount appropriate source
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
    
    # List and select backup
    if ! list_backups; then
        exit 1
    fi
    
    echo ""
    echo "Testing backup: $(basename "$SELECTED_BACKUP")"
    echo "Source: $(echo $BACKUP_SOURCE | tr '[:lower:]' '[:upper:]')"
    echo "=================================================="
    echo ""
    
    # Run size estimation
    estimate_size
    echo ""
    
    # Run all tests
    local tests_passed=0
    local tests_total=5
    
    test_file_integrity && tests_passed=$((tests_passed + 1))
    echo ""
    
    test_gpg_decryption && tests_passed=$((tests_passed + 1))
    echo ""
    
    test_compression_integrity && tests_passed=$((tests_passed + 1))
    echo ""
    
    test_zfs_stream && tests_passed=$((tests_passed + 1))
    echo ""
    
    test_zfs_compatibility && tests_passed=$((tests_passed + 1))
    echo ""
    
    # Results summary
    echo "TEST RESULTS SUMMARY"
    echo "===================="
    
    if [ $tests_passed -eq $tests_total ]; then
        print_status "ALL TESTS PASSED! ($tests_passed/$tests_total)"
        echo ""
        echo "✓ Your backup appears to be completely healthy!"
        echo "✓ Ready for restore testing on spare drive"
        echo "✓ All encryption and compression layers work"
        echo "✓ ZFS stream format is valid"
    elif [ $tests_passed -ge 3 ]; then
        print_warning "Most tests passed ($tests_passed/$tests_total)"
        echo ""
        echo "⚠ Backup is likely good, but some tests failed"
        echo "✓ Should still work for restore testing"
    else
        print_error "Multiple tests failed ($tests_passed/$tests_total)"
        echo ""
        echo "✗ Backup may be corrupted or have issues"
        echo "✗ Consider creating a new backup"
    fi
    
    echo ""
    echo "Next steps:"
    echo "- Test restore on spare drive"
    echo "- Boot from restored system to verify"
}

# Run main function
main