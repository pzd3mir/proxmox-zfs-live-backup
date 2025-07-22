#!/bin/bash
# NAS Functions Library - ZFS Backup System
# Handles NAS connectivity, mounting, and TrueNAS-specific operations
# Supports CIFS/SMB shares with credential management

# Test comprehensive NAS connectivity (extends basic test from credentials.sh)
test_nas_connectivity() {

    # First run the basic test from credentials.sh
    if ! test_network_connectivity "$NAS_IP" "$NAS_TIMEOUT"; then
        return 1
    fi

    # Check if we have required NAS credentials
    if [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ] || [ -z "$NAS_SHARE" ]; then
        return 1
    fi

    # Check if CIFS utils are available
    if ! command -v mount.cifs >/dev/null 2>&1; then
        return 1
    fi

    # Try to mount NAS share temporarily for full connectivity test
    local test_mount="/tmp/nas-test-$$"
    local test_result=1
    
    if mount_nas_share_to_path "$test_mount" >/dev/null 2>&1; then
        # Create backup directory if it doesn't exist and test write access there
        local backup_test_dir="$test_mount/$NAS_BACKUP_PATH"
        mkdir -p "$backup_test_dir" 2>/dev/null
        
        # Test if we can actually write to the backup directory
        if touch "$backup_test_dir/.write-test-$$" 2>/dev/null; then
            rm -f "$backup_test_dir/.write-test-$$" 2>/dev/null
            test_result=0
        fi
        umount "$test_mount" 2>/dev/null
    fi

    rmdir "$test_mount" 2>/dev/null
    return $test_result
}

# Mount NAS share to the default temporary mount point
mount_nas_share() {
    mount_nas_share_to_path "$TEMP_MOUNT"
}

# Mount NAS share to a specific path
mount_nas_share_to_path() {
    local mount_path="$1"
    
    if [ -z "$mount_path" ]; then
        print_error "No mount path specified for NAS share"
        return 1
    fi


    # Verify credentials are available
    if [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ] || [ -z "$NAS_IP" ] || [ -z "$NAS_SHARE" ]; then
        print_error "Missing NAS connection parameters"
        return 1
    fi

    # Create mount point
    mkdir -p "$mount_path"
    if [ ! -d "$mount_path" ]; then
        print_error "Failed to create mount point: $mount_path"
        return 1
    fi

    # Create temporary credentials file
    local temp_creds="/tmp/.nas-creds-$$"
    
    cat > "$temp_creds" << EOF
username=$NAS_USER
password=$NAS_PASSWORD
EOF

    chmod 600 "$temp_creds"

    # Mount CIFS/SMB share
    local mount_options="credentials=$temp_creds,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755,iocharset=utf8"
    
    
    if mount -t cifs "//$NAS_IP/$NAS_SHARE" "$mount_path" -o "$mount_options" 2>/dev/null; then
        # Clean up credentials file immediately
        rm -f "$temp_creds"
        
        # Verify mount is working
        if mountpoint -q "$mount_path" 2>/dev/null; then
            
            # Test write access in the backup directory, not share root
            local backup_test_dir="$mount_path/$NAS_BACKUP_PATH"
            mkdir -p "$backup_test_dir" 2>/dev/null
            if touch "$backup_test_dir/.mount-test-$$" 2>/dev/null; then
                rm -f "$backup_test_dir/.mount-test-$$" 2>/dev/null
            else
                print_warning "[WARNING] NAS share mounted but no write access to backup directory"
            fi
            
            return 0
        else
            print_error "NAS share mount failed: not properly mounted"
            rm -f "$temp_creds"
            return 1
        fi
    else
        print_error "Failed to mount NAS share: //$NAS_IP/$NAS_SHARE"
        rm -f "$temp_creds"
        return 1
    fi
}

# Unmount NAS share safely
unmount_nas_share() {
    local mount_path="${1:-$TEMP_MOUNT}"
    
    if [ ! -d "$mount_path" ]; then
        return 0
    fi

    if ! mountpoint -q "$mount_path" 2>/dev/null; then
        return 0
    fi

    
    # Try gentle unmount first
    if umount "$mount_path" 2>/dev/null; then
        return 0
    fi

    # Try lazy unmount if gentle fails
    print_warning "Standard unmount failed, trying lazy unmount..."
    if umount -l "$mount_path" 2>/dev/null; then
        return 0
    fi

    print_error "[ERROR] Failed to unmount NAS share: $mount_path"
    return 1
}

# Check NAS storage space and requirements  
check_nas_space_requirements() {
    local mount_path="${1:-$TEMP_MOUNT}"
    local required_gb="${2:-15}"  # Default 15GB requirement
    
    if ! mountpoint -q "$mount_path" 2>/dev/null; then
        print_error "NAS share not mounted at: $mount_path"
        return 1
    fi

    # Get available space in GB
    local available_bytes=$(df -B1 "$mount_path" | tail -1 | awk '{print $4}')
    local available_gb=$((available_bytes / 1024 / 1024 / 1024))
    local available_mb=$((available_bytes / 1024 / 1024))
    

    if [ "$available_gb" -lt "$required_gb" ]; then
        print_error "[ERROR] Insufficient space on NAS"
        print_info "Required: ${required_gb}GB"
        print_info "Available: ${available_gb}GB (${available_mb}MB)"
        return 1
    fi

    print_status "[OK] NAS space available: ${available_gb}GB (${available_mb}MB)"
    return 0
}

# Create backup directory structure on NAS
create_nas_backup_directory() {
    local mount_path="${1:-$TEMP_MOUNT}"
    local backup_path="${2:-$NAS_BACKUP_PATH}"
    
    if [ -z "$backup_path" ]; then
        print_error "No backup path specified"
        return 1
    fi

    if ! mountpoint -q "$mount_path" 2>/dev/null; then
        print_error "NAS share not mounted at: $mount_path"
        return 1
    fi

    local full_backup_dir="$mount_path/$backup_path"

    # Create directory structure
    if mkdir -p "$full_backup_dir" 2>/dev/null; then
        # Verify we can write to the directory
        if touch "$full_backup_dir/.write-test-$$" 2>/dev/null; then
            rm -f "$full_backup_dir/.write-test-$$"
            print_status "[OK] NAS backup directory ready: $backup_path"
            return 0
        else
            print_error "Cannot write to NAS backup directory: $full_backup_dir"
            return 1
        fi
    else
        print_error "Failed to create NAS backup directory: $full_backup_dir"
        return 1
    fi
}

# Validate NAS configuration before operations
validate_nas_configuration() {
    
    # Check required variables
    local missing_vars=()
    
    [ -z "$NAS_IP" ] && missing_vars+=("NAS_IP")
    [ -z "$NAS_SHARE" ] && missing_vars+=("NAS_SHARE")
    [ -z "$NAS_USER" ] && missing_vars+=("NAS_USER")
    [ -z "$NAS_PASSWORD" ] && missing_vars+=("NAS_PASSWORD")
    [ -z "$NAS_BACKUP_PATH" ] && missing_vars+=("NAS_BACKUP_PATH")
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        print_error "[ERROR] Missing NAS configuration variables: ${missing_vars[*]}"
        print_info "💡 Run: $0 setup"
        return 1
    fi
    
    # Check for required system packages
    if ! command -v mount.cifs >/dev/null 2>&1; then
        print_error "[ERROR] CIFS utilities not installed"
        print_info "💡 Install: apt install cifs-utils"
        return 1
    fi
    
    return 0
}