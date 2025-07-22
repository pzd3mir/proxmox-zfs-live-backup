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

# Configuration (use same as reference)
NAS_IP="192.168.178.12"
NAS_SHARE="backups"
BACKUP_PATH="NAS/proxmox/system-images"
MOUNT_POINT="/mnt/backup-test"
USB_MOUNT_POINT="/mnt/usb-test"
CREDENTIALS_FILE="/root/.zfs-backup-credentials"

# Global variables
BACKUP_SOURCE=""
SELECTED_BACKUP=""
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

# Select backup source for integrity checking
select_integrity_source() {
    print_section_header "= BACKUP SOURCE SELECTION"
    print_info "Choose backup source to verify:"
    
    echo "1) < NAS/Network backup"
    echo "2) =� USB/External drive backup"
    echo "3) =� Local directory backup"
    echo ""
    
    local source_choice=""
    read -p "Select source (1/2/3): " source_choice
    echo ""
    
    case "$source_choice" in
        1)
            print_status "Selected: NAS/Network backup"
            BACKUP_SOURCE="nas"
            mount_nas_for_integrity
            ;;
        2)
            print_status "Selected: USB/External drive backup"
            BACKUP_SOURCE="usb"
            mount_usb_for_integrity
            ;;
        3)
            print_status "Selected: Local directory backup"
            BACKUP_SOURCE="local"
            get_local_backup_path
            ;;
        *)
            print_error "Invalid selection"
            exit 1
            ;;
    esac
}

# Mount NAS share for integrity checking
mount_nas_for_integrity() {
    print_info "Connecting to NAS for integrity check..."
    
    # Load credentials
    if ! load_backup_credentials; then
        print_error "Cannot load NAS credentials"
        print_info "Run: $0 setup"
        exit 1
    fi
    
    # Test connectivity first
    if ! test_nas_connectivity; then
        print_error "Cannot connect to NAS"
        exit 1
    fi
    
    # Mount NAS share using existing function
    if ! mount_nas_share; then
        print_error "Failed to mount NAS share"
        exit 1
    fi
    
    BACKUP_LOCATION="$TEMP_MOUNT/$NAS_BACKUP_PATH"
    print_status "NAS mounted successfully"
    print_info "Backup location: $BACKUP_LOCATION"
}

# Mount USB drive for integrity checking
mount_usb_for_integrity() {
    print_info "Detecting USB drives for integrity check..."
    
    # Use existing USB detection with modified mount point
    export USB_MOUNT_POINT="$TEMP_MOUNT"
    
    if ! list_usb_drives; then
        print_error "No USB drives found or selected"
        exit 1
    fi
    
    if ! mount_usb_device "$SELECTED_TARGET"; then
        print_error "Failed to mount USB device"
        exit 1
    fi
    
    BACKUP_LOCATION="$TEMP_MOUNT"
    print_status "USB drive mounted successfully"
    print_info "Backup location: $BACKUP_LOCATION"
}

# Get local backup directory path
get_local_backup_path() {
    echo "=� Local Backup Directory"
    echo "========================="
    echo ""
    
    read -p "Enter path to backup directory: " local_path
    
    if [ ! -d "$local_path" ]; then
        print_error "Directory does not exist: $local_path"
        exit 1
    fi
    
    BACKUP_LOCATION="$local_path"
    print_status "Using local directory: $local_path"
}

# List and select backup files for verification
select_backup_files() {
    print_section_header "=� AVAILABLE BACKUPS"
    
    if [ ! -d "$BACKUP_LOCATION" ]; then
        print_error "Backup location not accessible: $BACKUP_LOCATION"
        exit 1
    fi
    
    print_info "Scanning for backup files in: $BACKUP_LOCATION"
    
    # Analyze backup structure
    analyze_backup_structure "$BACKUP_LOCATION"
    
    local backup_files=()
    local count=1
    
    echo ""
    echo "Available backup sets:"
    echo "====================="
    
    # Group backups by date/session
    local backup_dates=()
    
    # Find all backup files and extract dates
    for file in "$BACKUP_LOCATION"/*.gpg; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            local date_part=$(echo "$basename" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
            
            if [ -n "$date_part" ] && [[ ! " ${backup_dates[@]} " =~ " ${date_part} " ]]; then
                backup_dates+=("$date_part")
            fi
        fi
    done
    
    # Display backup sets grouped by date
    for date in "${backup_dates[@]}"; do
        echo "$count) Backup Set: $date"
        
        local boot_file=""
        local zfs_file=""
        local total_size=0
        
        # Find components for this date
        for file in "$BACKUP_LOCATION"/*${date}*.gpg; do
            if [ -f "$file" ]; then
                local basename=$(basename "$file")
                local size=$(ls -lh "$file" | awk '{print $5}')
                local size_bytes=$(stat -c%s "$file" 2>/dev/null || echo "0")
                total_size=$((total_size + size_bytes))
                
                if [[ "$basename" == boot-partition-* ]]; then
                    boot_file="$file"
                    echo "   =� Boot partition: $basename ($size)"
                elif [[ "$basename" == *backup* ]] || [[ "$basename" == *zfs* ]]; then
                    zfs_file="$file"
                    echo "   =� ZFS data: $basename ($size)"
                fi
            fi
        done
        
        local total_gb=$((total_size / 1024 / 1024 / 1024))
        echo "   =� Total size: ${total_gb}GB"
        
        # Store the main ZFS file for selection (most important component)
        if [ -n "$zfs_file" ]; then
            backup_files[$count]="$zfs_file"
        elif [ -n "$boot_file" ]; then
            backup_files[$count]="$boot_file"
        fi
        
        echo ""
        count=$((count + 1))
    done
    
    if [ $count -eq 1 ]; then
        print_error "No backup files found in $BACKUP_LOCATION"
        print_info "Looking for files matching: *.gpg"
        ls -la "$BACKUP_LOCATION"/*.gpg 2>/dev/null || echo "No .gpg files found"
        exit 1
    fi
    
    echo "Select backup set to verify (1-$((count-1))) or 'q' to quit:"
    local selection=""
    read -p "Choice: " selection
    
    if [ "$selection" = "q" ]; then
        print_info "Integrity check cancelled"
        exit 0
    elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -lt "$count" ]; then
        SELECTED_BACKUP="${backup_files[$selection]}"
        print_status "Selected backup: $(basename "$SELECTED_BACKUP")"
        
        # Also check if we have a complete hybrid backup set
        local selected_date=$(basename "$SELECTED_BACKUP" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
        print_info "Will verify all components from backup set: $selected_date"
    else
        print_error "Invalid selection"
        exit 1
    fi
}

# Get encryption password for verification
get_verification_password() {
    print_section_header "= ENCRYPTION PASSWORD"
    
    # Try to load from credentials first
    if [ -f "$CREDENTIALS_FILE" ]; then
        local stored_pass=$(grep "^encryption_password=" "$CREDENTIALS_FILE" | cut -d'=' -f2- 2>/dev/null || true)
        if [ -n "$stored_pass" ]; then
            print_info "Using stored encryption password"
            ENCRYPTION_PASS="$stored_pass"
            return 0
        fi
    fi
    
    # Prompt for password
    echo "Enter backup encryption password:"
    read -s -p "Password: " ENCRYPTION_PASS
    echo ""
    
    if [ ${#ENCRYPTION_PASS} -lt 8 ]; then
        print_error "Password too short (minimum 8 characters)"
        exit 1
    fi
    
    print_status "Password accepted"
}

# Verify backup set integrity
verify_backup_set() {
    local selected_date=$(basename "$SELECTED_BACKUP" | grep -o '[0-9]\{8\}-[0-9]\{4\}' | head -1)
    
    print_section_header ">� BACKUP SET VERIFICATION"
    print_info "Verifying backup set: $selected_date"
    echo ""
    
    local verification_passed=true
    local total_tests=0
    local passed_tests=0
    
    # Find all components for this backup set
    local boot_files=()
    local zfs_files=()
    
    for file in "$BACKUP_LOCATION"/*${selected_date}*.gpg; do
        if [ -f "$file" ]; then
            local basename=$(basename "$file")
            if [[ "$basename" == boot-partition-* ]]; then
                boot_files+=("$file")
            elif [[ "$basename" == *backup* ]] || [[ "$basename" == *zfs* ]]; then
                zfs_files+=("$file")
            fi
        fi
    done
    
    # Verify boot partition files
    if [ ${#boot_files[@]} -gt 0 ]; then
        print_info "= Verifying boot partition files..."
        for boot_file in "${boot_files[@]}"; do
            print_info "Testing: $(basename "$boot_file")"
            
            # Quick integrity test for boot files
            if quick_integrity_test "$boot_file" "$ENCRYPTION_PASS"; then
                print_status " Boot partition file verified"
                passed_tests=$((passed_tests + 1))
            else
                print_error "L Boot partition file verification failed"
                verification_passed=false
            fi
            total_tests=$((total_tests + 1))
            echo ""
        done
    fi
    
    # Verify ZFS backup files (comprehensive)
    if [ ${#zfs_files[@]} -gt 0 ]; then
        print_info "= Verifying ZFS backup files..."
        for zfs_file in "${zfs_files[@]}"; do
            print_info "Testing: $(basename "$zfs_file")"
            
            # Detect compression type from filename or use default
            local compression="gzip"
            if [[ "$zfs_file" == *.xz.gpg ]]; then
                compression="xz"
            fi
            
            # Run comprehensive validation
            if run_comprehensive_backup_validation "$zfs_file" "$ENCRYPTION_PASS" "$compression"; then
                print_status " ZFS backup file verified"
                passed_tests=$((passed_tests + 5))  # Comprehensive test counts as 5
            else
                print_error "L ZFS backup file verification failed"
                verification_passed=false
            fi
            total_tests=$((total_tests + 5))
            echo ""
        done
    fi
    
    # Show size estimation
    if [ ${#zfs_files[@]} -gt 0 ]; then
        estimate_backup_size "${zfs_files[0]}"
        echo ""
    fi
    
    # Final results
    print_section_header "<� VERIFICATION SUMMARY"
    
    if [ "$verification_passed" = true ]; then
        print_status "ALL VERIFICATIONS PASSED! ($passed_tests/$total_tests tests)"
        echo ""
        print_info " Backup set '$selected_date' is healthy and complete"
        print_info " All encryption and compression layers are intact"
        print_info " ZFS stream format is valid"
        print_info " Ready for restore operations"
        echo ""
        print_info "=� NEXT STEPS:"
        echo "" Test restore on spare hardware using: ./restore.sh"
        echo "" Verify restore boots successfully"
        echo "" Consider this backup set safe for production use"
    else
        print_error "VERIFICATION FAILED! ($passed_tests/$total_tests tests passed)"
        echo ""
        print_error "L Backup set '$selected_date' has integrity issues"
        print_error "L Some components may be corrupted"
        print_info "=' RECOMMENDED ACTIONS:"
        echo "" Create a new backup to replace this one"
        echo "" Check source system for issues"
        echo "" Verify network/storage reliability"
        echo "" Do not use this backup for critical restores"
    fi
    
    return $([ "$verification_passed" = true ] && echo 0 || echo 1)
}

# Print help information
print_help() {
    cat << EOF
ZFS Backup Integrity Check Tool

USAGE:
  $0 [OPTIONS]

DESCRIPTION:
  Verifies the integrity of ZFS backup files without performing restore
  operations. Supports both hybrid backups (boot partition + ZFS) and 
  ZFS-only backups from various sources.

OPTIONS:
  --help          Show this help message
  --debug         Enable debug output
  --quiet         Suppress non-essential output

FEATURES:
   Comprehensive backup validation
   GPG encryption integrity testing
   Compression format verification
   ZFS stream format validation
   Multi-source support (NAS/USB/Local)
   Hybrid backup component analysis
   Size estimation and requirements

SOURCES SUPPORTED:
  " NAS/Network shares (SMB/CIFS)
  " USB/External drives
  " Local directories

VERIFICATION TESTS:
  1. File integrity and accessibility
  2. GPG encryption/decryption
  3. Compression format integrity
  4. ZFS stream format validation
  5. ZFS compatibility testing

EXAMPLES:
  $0                    # Interactive mode
  $0 --debug           # With debug output
  
EXIT CODES:
  0  All verifications passed
  1  Verification failed or error occurred

For backup creation, use: ./zfs-backup.sh
For backup restoration, use: ./restore.sh
EOF
}

# Main execution function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                print_help
                exit 0
                ;;
            --debug)
                export DEBUG_MODE=true
                shift
                ;;
            --quiet)
                export DEBUG_MODE=false
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Print header
    print_main_header ">� ZFS BACKUP INTEGRITY CHECKER"
    echo "System: $(hostname) | User: $(whoami) | Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    print_info "This tool verifies backup integrity without modifying any data"
    print_info "Supported sources: NAS, USB drives, local directories"
    echo ""
    
    # Load default configuration
    load_default_config 2>/dev/null || {
        # Set minimal config for integrity checking
        export CREDENTIALS_FILE="${HOME:-/root}/.zfs-backup-credentials"
        export NAS_IP="${NAS_IP:-192.168.1.100}"
        export NAS_SHARE="${NAS_SHARE:-backups}"
        export NAS_BACKUP_PATH="${NAS_BACKUP_PATH:-NAS/proxmox/system-images}"
    }
    
    # Create temporary mount point
    mkdir -p "$TEMP_MOUNT"
    
    # Select backup source
    select_integrity_source
    
    # Select backup files
    select_backup_files
    
    # Get encryption password
    get_verification_password
    
    # Quick verification first
    print_info "Testing encryption password..."
    if ! quick_integrity_test "$SELECTED_BACKUP" "$ENCRYPTION_PASS"; then
        print_error "Cannot decrypt backup with provided password"
        exit 1
    fi
    print_status "Password verification successful"
    echo ""
    
    # Run comprehensive verification
    if verify_backup_set; then
        print_main_header "<� INTEGRITY CHECK COMPLETED SUCCESSFULLY!"
        exit 0
    else
        print_main_header "L INTEGRITY CHECK FAILED!"
        exit 1
    fi
}

# Check if running as root (not required for integrity checking)
if [ "$(id -u)" -eq 0 ]; then
    print_warning "Running as root is not required for integrity checking"
    print_info "Consider running as regular user for safety"
    echo ""
fi

# Run main function
main "$@"