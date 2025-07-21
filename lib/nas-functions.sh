#!/bin/bash
# NAS Functions Library - ZFS Backup System
# Handles NAS connectivity, mounting, and TrueNAS-specific operations
# Supports CIFS/SMB shares with credential management

# Test comprehensive NAS connectivity (extends basic test from credentials.sh)
test_nas_connectivity() {
    print_debug "Testing comprehensive NAS connectivity..."

    # First run the basic test from credentials.sh
    if ! test_network_connectivity "$NAS_IP" "$NAS_TIMEOUT"; then
        print_debug "Basic network test failed"
        return 1
    fi

    # Check if we have required NAS credentials
    if [ -z "$NAS_USER" ] || [ -z "$NAS_PASSWORD" ] || [ -z "$NAS_SHARE" ]; then
        print_debug "Missing NAS credentials or share information"
        return 1
    fi

    # Check if CIFS utils are available
    if ! command -v mount.cifs >/dev/null 2>&1; then
        print_debug "CIFS utilities not available"
        return 1
    fi

    # Try to mount NAS share temporarily for full connectivity test
    local test_mount="/tmp/nas-test-$$"
    local test_result=1
    
    if mount_nas_share_to_path "$test_mount" >/dev/null 2>&1; then
        # Test if we can actually write to the share
        if touch "$test_mount/.write-test-$$" 2>/dev/null; then
            rm -f "$test_mount/.write-test-$$" 2>/dev/null
            test_result=0
            print_debug "NAS connectivity test: PASSED (mount and write successful)"
        else
            print_debug "NAS connectivity test: FAILED (cannot write to share)"
        fi
        umount "$test_mount" 2>/dev/null
    else
        print_debug "NAS connectivity test: FAILED (cannot mount share)"
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

    print_debug "Mounting NAS share to: $mount_path"

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
    print_debug "Creating temporary NAS credentials file"
    
    cat > "$temp_creds" << EOF
username=$NAS_USER
password=$NAS_PASSWORD
EOF

    chmod 600 "$temp_creds"

    # Mount CIFS/SMB share
    local mount_options="credentials=$temp_creds,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755,iocharset=utf8"
    
    print_debug "Mounting: //$NAS_IP/$NAS_SHARE -> $mount_path"
    
    if mount -t cifs "//$NAS_IP/$NAS_SHARE" "$mount_path" -o "$mount_options" 2>/dev/null; then
        # Clean up credentials file immediately
        rm -f "$temp_creds"
        
        # Verify mount is working
        if mountpoint -q "$mount_path" 2>/dev/null; then
            print_debug "✅ NAS share mounted successfully"
            
            # Test write access
            if touch "$mount_path/.mount-test-$$" 2>/dev/null; then
                rm -f "$mount_path/.mount-test-$$" 2>/dev/null
                print_debug "✅ NAS share has write access"
            else
                print_warning "⚠️  NAS share mounted but no write access"
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
        print_debug "Mount path does not exist: $mount_path"
        return 0
    fi

    if ! mountpoint -q "$mount_path" 2>/dev/null; then
        print_debug "Path is not a mount point: $mount_path"
        return 0
    fi

    print_debug "Unmounting NAS share: $mount_path"
    
    # Try gentle unmount first
    if umount "$mount_path" 2>/dev/null; then
        print_debug "✅ NAS share unmounted successfully"
        return 0
    fi

    # Try lazy unmount if gentle fails
    print_warning "Standard unmount failed, trying lazy unmount..."
    if umount -l "$mount_path" 2>/dev/null; then
        print_debug "✅ NAS share unmounted with lazy unmount"
        return 0
    fi

    print_error "❌ Failed to unmount NAS share: $mount_path"
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
    
    print_debug "NAS space check: ${available_gb}GB available, ${required_gb}GB required"

    if [ "$available_gb" -lt "$required_gb" ]; then
        print_error "❌ Insufficient space on NAS"
        print_info "Required: ${required_gb}GB"
        print_info "Available: ${available_gb}GB (${available_mb}MB)"
        return 1
    fi

    print_status "✅ NAS space available: ${available_gb}GB (${available_mb}MB)"
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
    print_debug "Creating NAS backup directory: $full_backup_dir"

    # Create directory structure
    if mkdir -p "$full_backup_dir" 2>/dev/null; then
        # Verify we can write to the directory
        if touch "$full_backup_dir/.write-test-$$" 2>/dev/null; then
            rm -f "$full_backup_dir/.write-test-$$"
            print_status "✅ NAS backup directory ready: $backup_path"
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
    print_debug "Validating NAS configuration..."
    
    # Check required variables
    local missing_vars=()
    
    [ -z "$NAS_IP" ] && missing_vars+=("NAS_IP")
    [ -z "$NAS_SHARE" ] && missing_vars+=("NAS_SHARE")
    [ -z "$NAS_USER" ] && missing_vars+=("NAS_USER")
    [ -z "$NAS_PASSWORD" ] && missing_vars+=("NAS_PASSWORD")
    [ -z "$NAS_BACKUP_PATH" ] && missing_vars+=("NAS_BACKUP_PATH")
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        print_error "❌ Missing NAS configuration variables: ${missing_vars[*]}"
        print_info "💡 Run: $0 setup"
        return 1
    fi
    
    # Check for required system packages
    if ! command -v mount.cifs >/dev/null 2>&1; then
        print_error "❌ CIFS utilities not installed"
        print_info "💡 Install: apt install cifs-utils"
        return 1
    fi
    
    print_debug "✅ NAS configuration validation passed"
    return 0
}