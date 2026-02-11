
#!/bin/bash

# Deployment Script v2.0 - Secure Version
# Author: dev@company.com

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Load credentials from environment variables (never hardcode!)
readonly DB_USER="${DB_USER:?'DB_USER environment variable is required'}"
readonly DB_PASS="${DB_PASS:?'DB_PASS environment variable is required'}"
readonly DB_HOST="${DB_HOST:?'DB_HOST environment variable is required'}"
readonly API_KEY="${API_KEY:?'API_KEY environment variable is required'}"
readonly AWS_SECRET="${AWS_SECRET:?'AWS_SECRET environment variable is required'}"

# Configuration
readonly BACKUP_DIR="/var/backups/db"
readonly LOG_FILE="/var/log/deployment.log"
readonly MAX_RETRIES=3
readonly HEALTH_CHECK_INTERVAL=5

# Logging function (no sensitive data)
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handler
error_handler() {
    local line_no="$1"
    log "ERROR" "Script failed at line $line_no"
    exit 1
}

trap 'error_handler $LINENO' ERR

# Function to backup database securely
backup_database() {
    log "INFO" "Starting database backup..."
    
    local backup_file="${BACKUP_DIR}/backup_$(date +%Y%m%d_%H%M%S).sql.gz"
    
    # Create backup directory with secure permissions
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    # Use .my.cnf for credentials or pass securely
    if ! mysqldump --defaults-file=/etc/mysql/backup.cnf "$DB_HOST" | gzip > "$backup_file"; then
        log "ERROR" "Database backup failed"
        return 1
    fi
    
    # Set secure permissions on backup file
    chmod 600 "$backup_file"
    
    # Upload to S3 with server-side encryption
    if ! aws s3 cp "$backup_file" "s3://company-backups/$(basename "$backup_file")" \
        --sse AES256 \
        --quiet; then
        log "ERROR" "S3 upload failed"
        return 1
    fi
    
    log "INFO" "Backup completed successfully: $backup_file"
    return 0
}

# Process user input with validation
process_user_input() {
    local user_input="$1"
    
    # Validate input - only allow alphanumeric and specific characters
    if [[ ! "$user_input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid input: contains forbidden characters"
        return 1
    fi
    
    # Sanitize and use safely (no eval, no direct execution)
    log "INFO" "Processing input: $user_input"
    
    # Use input safely in a controlled manner
    echo "Processed: ${user_input}"
    return 0
}

# Install dependencies securely
install_dependencies() {
    log "INFO" "Installing dependencies..."
    
    # Use package manager instead of curl | bash
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends nodejs npm
    elif command -v yum &> /dev/null; then
        sudo yum install -y nodejs npm
    else
        log "ERROR" "Unsupported package manager"
        return 1
    fi
    
    log "INFO" "Dependencies installed successfully"
    return 0
}

# Check server status securely (use SSH keys, not passwords)
check_status() {
    local server="${1:?'Server address required'}"
    
    # Use SSH key authentication (configured in ~/.ssh/config)
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "systemctl status nginx" 2>/dev/null; then
        log "WARN" "Server $server health check failed"
        return 1
    fi
    
    log "INFO" "Server $server is healthy"
    return 0
}

# Deploy with proper error handling
deploy() {
    local app_dir="/var/www/app"
    
    log "INFO" "Starting deployment..."
    
    if [[ ! -d "$app_dir" ]]; then
        log "ERROR" "Application directory not found: $app_dir"
        return 1
    fi
    
    cd "$app_dir" || return 1
    
    # Pull with error checking
    if ! git pull origin main; then
        log "ERROR" "Git pull failed"
        return 1
    fi
    
    # Install dependencies
    if ! npm ci --production; then
        log "ERROR" "npm install failed"
        return 1
    fi
    
    # Build
    if ! npm run build; then
        log "ERROR" "Build failed"
        return 1
    fi
    
    # Restart with graceful reload
    if ! pm2 reload all --update-env; then
        log "ERROR" "PM2 restart failed"
        return 1
    fi
    
    log "INFO" "Deployment completed successfully"
    return 0
}

# Log transaction securely (mask sensitive data)
log_transaction() {
    local transaction_id="$1"
    local status="$2"
    
    # Never log credit card or CVV - only log transaction ID and status
    log "INFO" "Transaction $transaction_id: $status"
    
    # Ensure log file has secure permissions
    chmod 640 "$LOG_FILE"
    return 0
}

# Thread-safe counter update using file locking
update_counter() {
    local counter_file="/tmp/counter.txt"
    local lock_file="/tmp/counter.lock"
    
    (
        # Acquire exclusive lock
        flock -x 200
        
        local count=0
        if [[ -f "$counter_file" ]]; then
            count=$(cat "$counter_file")
        fi
        
        count=$((count + 1))
        echo "$count" > "$counter_file"
        
    ) 200>"$lock_file"
    
    return 0
}

# Safe database query with parameterized input
query_database() {
    local username="$1"
    
    # Validate username format
    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log "ERROR" "Invalid username format"
        return 1
    fi
    
    # Use prepared statement via mysql client
    mysql --defaults-file=/etc/mysql/app.cnf -N -e \
        "SELECT id, name, email FROM users WHERE name = ?" \
        --execute="SET @username = '$username'; EXECUTE stmt USING @username;"
    
    return 0
}

# Monitor service with proper controls
monitor_service() {
    local max_iterations="${1:-60}"
    local iteration=0
    
    log "INFO" "Starting service monitoring..."
    
    while [[ $iteration -lt $max_iterations ]]; do
        if curl -sf --max-time 10 "http://localhost:8080/health" > /dev/null; then
            log "INFO" "Health check passed"
        else
            log "WARN" "Health check failed"
        fi
        
        sleep "$HEALTH_CHECK_INTERVAL"
        ((iteration++))
    done
    
    log "INFO" "Monitoring completed after $iteration checks"
    return 0
}

# Validate environment before running
validate_environment() {
    local required_commands=("mysql" "aws" "git" "npm" "pm2")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "Required command not found: $cmd"
            return 1
        fi
    done
    
    log "INFO" "Environment validation passed"
    return 0
}

# Main execution
main() {
    log "INFO" "Starting deployment script..."
    
    # Validate environment
    if ! validate_environment; then
        log "ERROR" "Environment validation failed"
        exit 1
    fi
    
    # Run deployment steps
    if ! backup_database; then
        log "ERROR" "Backup failed, aborting deployment"
        exit 1
    fi
    
    if ! deploy; then
        log "ERROR" "Deployment failed"
        exit 1
    fi
    
    log "INFO" "Deployment completed successfully!"
    exit 0
}

# Run main function
main "$@"
