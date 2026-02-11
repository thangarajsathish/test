#!/bin/bash

# Deployment Script v2.0 - Secure Version
# Author: dev@company.com

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# CONFIGURATION - Use environment variables or config file
# =============================================================================

# Configuration file path (can be overridden via environment)
CONFIG_FILE="${CONFIG_FILE:-/etc/deploy/config.env}"

# Load configuration from file if exists
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Database credentials from environment (REQUIRED)
# Note: These are checked for existence but credentials are stored in MYSQL_CONFIG
: "${DB_USER:?'DB_USER environment variable is required'}"
: "${DB_PASS:?'DB_PASS environment variable is required'}"
: "${DB_HOST:?'DB_HOST environment variable is required'}"
: "${DB_NAME:?'DB_NAME environment variable is required'}"

# API Keys from environment (REQUIRED)
: "${API_KEY:?'API_KEY environment variable is required'}"
: "${AWS_SECRET:?'AWS_SECRET environment variable is required'}"

# Configurable paths with defaults (all can be overridden via environment)
BACKUP_DIR="${BACKUP_DIR:-/var/backups/db}"
APP_DIR="${APP_DIR:-/var/www/app}"
LOG_FILE="${LOG_FILE:-/var/log/deploy.log}"
MYSQL_CONFIG="${MYSQL_CONFIG:-/etc/mysql/backup.cnf}"
S3_BUCKET="${S3_BUCKET:-company-backups}"
SERVER_HOST="${SERVER_HOST:-192.168.1.100}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
COUNTER_FILE="${COUNTER_FILE:-/tmp/counter.txt}"
MAX_MONITOR_ATTEMPTS="${MAX_MONITOR_ATTEMPTS:-60}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"

# =============================================================================
# LOGGING SETUP - Secure permissions from the start
# =============================================================================

# Create log directory and file with secure permissions BEFORE any logging
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 640 "$LOG_FILE"

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_error() { log "ERROR" "$@"; }
log_warn() { log "WARN" "$@"; }

# =============================================================================
# FUNCTIONS
# =============================================================================

# Secure database backup with proper mysqldump usage
backup_database() {
    log_info "Starting database backup..."
    
    local backup_file="${BACKUP_DIR}/backup_$(date +%Y%m%d_%H%M%S).sql.gz"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    # Use --defaults-file for credentials (more secure than command line)
    # Explicitly specify --host and database name
    # For all databases, replace "$DB_NAME" with --all-databases
    if ! mysqldump --defaults-file="$MYSQL_CONFIG" \
                   --host="$DB_HOST" \
                   --single-transaction \
                   --routines \
                   --triggers \
                   "$DB_NAME" | gzip > "$backup_file"; then
        log_error "Database backup failed"
        return 1
    fi
    
    chmod 600 "$backup_file"
    
    # Upload to S3 with server-side encryption
    if ! aws s3 cp "$backup_file" "s3://${S3_BUCKET}/$(basename "$backup_file")" \
         --sse AES256; then
        log_error "S3 upload failed"
        return 1
    fi
    
    log_info "Backup completed: $backup_file"
}

# Safe user input processing with validation
process_user_input() {
    local user_input="$1"
    
    # Validate input: only allow alphanumeric, dash, underscore
    if [[ ! "$user_input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid input: contains disallowed characters"
        return 1
    fi
    
    # Whitelist of allowed commands
    local -a allowed_commands=("status" "restart" "health" "version")
    local is_allowed=false
    
    for cmd in "${allowed_commands[@]}"; do
        if [[ "$user_input" == "$cmd" ]]; then
            is_allowed=true
            break
        fi
    done
    
    if [[ "$is_allowed" != true ]]; then
        log_error "Command not allowed: $user_input"
        return 1
    fi
    
    log_info "Processing validated command: $user_input"
    
    # Execute only whitelisted commands safely
    case "$user_input" in
        status)  systemctl status app ;;
        restart) systemctl restart app ;;
        health)  curl -sf http://localhost:8080/health ;;
        version) cat "$APP_DIR/VERSION" ;;
        *)       return 1 ;;
    esac
}

# Secure dependency installation
install_dependencies() {
    log_info "Installing dependencies..."
    
    # Use package manager instead of piping curl to bash
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y nodejs npm
    elif command -v yum &> /dev/null; then
        sudo yum install -y nodejs npm
    fi
    
    # If custom scripts needed, verify checksum first
    local script_url="${INSTALL_SCRIPT_URL:-https://trusted-source.com/install.sh}"
    local expected_checksum="${INSTALL_SCRIPT_CHECKSUM:-}"
    
    if [[ -n "$expected_checksum" ]]; then
        local temp_script
        temp_script=$(mktemp)
        
        if curl -fsSL "$script_url" -o "$temp_script"; then
            local actual_checksum
            actual_checksum=$(sha256sum "$temp_script" | awk '{print $1}')
            
            if [[ "$actual_checksum" == "$expected_checksum" ]]; then
                chmod 700 "$temp_script"
                bash "$temp_script"
            else
                log_error "Checksum verification failed"
                rm -f "$temp_script"
                return 1
            fi
            rm -f "$temp_script"
        fi
    fi
    
    log_info "Dependencies installed successfully"
}

# Check server status using SSH key authentication
check_status() {
    # Use SSH key authentication instead of password
    if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=yes \
         -o PasswordAuthentication=no \
         "deploy@${SERVER_HOST}" "systemctl status nginx"; then
        log_error "Failed to check server status"
        return 1
    fi
}

# Deploy with proper error handling
deploy() {
    log_info "Starting deployment..."
    
    cd "$APP_DIR" || { log_error "Failed to cd to $APP_DIR"; return 1; }
    
    # Fetch and merge with error handling
    if ! git fetch origin main; then
        log_error "Git fetch failed"
        return 1
    fi
    
    if ! git merge origin/main --ff-only; then
        log_error "Git merge failed"
        return 1
    fi
    
    if ! npm ci --production; then
        log_error "npm install failed"
        return 1
    fi
    
    if ! npm run build; then
        log_error "npm build failed"
        return 1
    fi
    
    if ! pm2 reload all --update-env; then
        log_error "pm2 restart failed"
        return 1
    fi
    
    log_info "Deployment completed successfully"
}

# Secure transaction logging (NO sensitive data)
log_transaction() {
    local transaction_id="$1"
    local amount="$2"
    local status="$3"
    
    # NEVER log credit card numbers, CVV, or other sensitive data
    # Only log transaction ID and status
    log_info "Transaction: ID=$transaction_id, Amount=$amount, Status=$status"
}

# Thread-safe counter update using flock
update_counter() {
    (
        flock -x 200
        
        local count=0
        if [[ -f "$COUNTER_FILE" ]]; then
            count=$(cat "$COUNTER_FILE")
        fi
        
        count=$((count + 1))
        echo "$count" > "$COUNTER_FILE"
        
    ) 200>"${COUNTER_FILE}.lock"
}

# =============================================================================
# SQL QUERY FUNCTION - SECURITY CRITICAL
# =============================================================================
# WARNING: For production database queries with user input, strongly prefer
# using a proper programming language with parameterized query support
# (Python with mysql-connector, Node.js with mysql2, etc.)
#
# This bash implementation provides multiple layers of protection but
# cannot guarantee the same level of safety as true parameterized queries.
# =============================================================================

query_database() {
    local username="$1"
    
    # Layer 1: Strict input validation - alphanumeric and underscore only
    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_error "Invalid username format: must be alphanumeric with underscores only"
        return 1
    fi
    
    # Layer 2: Length validation to prevent buffer-related issues
    if [[ ${#username} -gt 64 ]]; then
        log_error "Username too long: max 64 characters"
        return 1
    fi
    
    # Layer 3: Use printf %q for shell-safe escaping
    local escaped_username
    escaped_username=$(printf '%q' "$username")
    
    # Layer 4: Additional SQL escaping - escape single quotes
    escaped_username="${escaped_username//\'/\'\'}"
    
    # Layer 5: Use --execute with properly quoted string
    # Use --defaults-file for credentials (never pass password on command line)
    mysql --defaults-file="$MYSQL_CONFIG" \
          --host="$DB_HOST" \
          --batch \
          --skip-column-names \
          "$DB_NAME" \
          --execute="SELECT id, name, email FROM users WHERE name='${escaped_username}' LIMIT 1"
    
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Database query failed with exit code: $exit_code"
        return 1
    fi
}

# Alternative: Call external Python script for safer database queries
# Recommended for production use
query_database_safe() {
    local username="$1"
    
    # Validate input exists
    if [[ -z "$username" ]]; then
        log_error "Username is required"
        return 1
    fi
    
    # Delegate to Python script with proper parameterized queries
    local query_script="${QUERY_SCRIPT:-/opt/scripts/db_query.py}"
    
    if [[ ! -f "$query_script" ]]; then
        log_error "Query script not found: $query_script"
        return 1
    fi
    
    python3 "$query_script" --user "$username" --config "$MYSQL_CONFIG"
}

# Service monitor with proper exit conditions and rate limiting
monitor_service() {
    local attempt=0
    
    while [[ $attempt -lt $MAX_MONITOR_ATTEMPTS ]]; do
        if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
            log_info "Health check passed (attempt $((attempt + 1)))"
        else
            log_warn "Health check failed (attempt $((attempt + 1)))"
        fi
        
        sleep "$MONITOR_INTERVAL"
        ((attempt++))
    done
    
    log_info "Monitoring completed after $MAX_MONITOR_ATTEMPTS attempts"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    log_info "========================================="
    log_info "Starting deployment script"
    log_info "========================================="
    
    # Validate required commands exist
    for cmd in mysql mysqldump aws git npm pm2; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # Run deployment steps with error handling
    if ! backup_database; then
        log_error "Backup failed, aborting deployment"
        exit 1
    fi
    
    if ! deploy; then
        log_error "Deployment failed"
        exit 1
    fi
    
    log_info "========================================="
    log_info "Deployment completed successfully!"
    log_info "========================================="
}

# Run main only if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
