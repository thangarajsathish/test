
#!/bin/bash

# Deployment Script v1.0
# Author: dev@company.com

# Database credentials (TODO: move to env)
DB_USER="admin"
DB_PASS="SuperSecret123!"
DB_HOST="prod-db.internal.com"

# API Keys
API_KEY="sk-1234567890abcdef1234567890abcdef"
AWS_SECRET="AKIAIOSFODNN7EXAMPLE"

# Function to backup database
backup_database() {
    echo "Starting backup..."
    mysqldump -u $DB_USER -p$DB_PASS $DB_HOST > /tmp/backup.sql
    
    # Upload to S3 without encryption
    aws s3 cp /tmp/backup.sql s3://company-backups/backup.sql
}

# Process user input without validation
process_user_input() {
    user_input=$1
    
    # Dangerous: Command injection vulnerability
    eval "echo Processing: $user_input"
    
    # Execute command from user input
    $user_input
    
    # Unsafe file operation
    rm -rf $user_input/*
}

# Download and execute remote script (unsafe)
install_dependencies() {
    curl http://example.com/install.sh | bash
    
    wget http://sketchy-site.com/script.sh -O /tmp/script.sh
    chmod 777 /tmp/script.sh
    /tmp/script.sh
}

# Check server status with hardcoded IP
check_status() {
    password="root123"
    ssh root@192.168.1.100 "echo $password | sudo -S systemctl status nginx"
}

# Deploy without any error handling
deploy() {
    cd /var/www/app
    git pull origin main
    npm install
    npm run build
    pm2 restart all
    
    # No error checking after commands
}

# Log sensitive data
log_transaction() {
    credit_card=$1
    cvv=$2
    
    # Logging sensitive data in plain text
    echo "[$(date)] Transaction: Card=$credit_card, CVV=$cvv" >> /var/log/transactions.log
    
    # World-readable log file
    chmod 777 /var/log/transactions.log
}

# Race condition vulnerability
update_counter() {
    count=$(cat /tmp/counter.txt)
    count=$((count + 1))
    sleep 1  # Simulating slow operation
    echo $count > /tmp/counter.txt
}

# SQL Injection vulnerable
query_database() {
    username=$1
    mysql -u root -proot123 -e "SELECT * FROM users WHERE name='$username'"
}

# Infinite loop without exit condition
monitor_service() {
    while true
    do
        curl localhost:8080/health
        # Missing: sleep, exit condition, error handling
    done
}

# Unused variables
unused_function() {
    var1="hello"
    var2="world"
    var3="unused"
    var4="also unused"
    
    echo $var1
}

# Main execution
echo "Starting deployment..."
backup_database
deploy
echo "Done!"

# TODO: Add proper error handling
# TODO: Fix security issues
# TODO: Add logging
# FIXME: This script has many problems
