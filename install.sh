#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Database settings
DB_NAME="talkgo"
DB_USER="talkgo"
DB_PASS="talkgo123"
POSTGRES_PASS="159357Pv***"
PGADMIN_USER="pgadmin"
PGADMIN_PASS="pgadmin123"

# Function for logging
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    error "This script must be run as root (sudo ./install.sh)"
fi

# Install PostgreSQL
install_postgresql() {
    log "Installing PostgreSQL..."
    
    # Remove existing PostgreSQL installations
    apt-get remove --purge -y postgresql* pgadmin*
    rm -rf /etc/postgresql/
    rm -rf /var/lib/postgresql/
    rm -rf /var/log/postgresql/
    rm -f /etc/apt/sources.list.d/pgdg*
    rm -f /etc/apt/sources.list.d/postgresql*
    
    # Update package lists
    apt-get update
    
    # Install PostgreSQL
    apt-get install -y postgresql postgresql-contrib
    
    # Get PostgreSQL version
    PG_VERSION=$(psql --version | awk '{print $3}' | cut -d. -f1)
    log "PostgreSQL version: ${PG_VERSION}"
    
    # Create config directory if it doesn't exist
    PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
    log "Config directory: ${PG_CONF_DIR}"
    mkdir -p "${PG_CONF_DIR}"
    
    # Initialize database cluster
    log "Initializing database cluster..."
    pg_dropcluster --stop ${PG_VERSION} main || true
    pg_createcluster ${PG_VERSION} main
    
    # Configure PostgreSQL
    cat > "${PG_CONF_DIR}/postgresql.conf" << EOL
# Connection Settings
listen_addresses = '*'
port = 5432
max_connections = 100

# Memory Settings
shared_buffers = 128MB
work_mem = 4MB
maintenance_work_mem = 64MB

# Write Ahead Log
wal_level = replica
max_wal_size = 1GB
min_wal_size = 80MB

# Client Connection Defaults
client_encoding = 'UTF8'
timezone = 'UTC'

# Security
password_encryption = 'scram-sha-256'

# Error Reporting and Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 10MB
log_min_messages = warning
EOL

    # Configure pg_hba.conf
    cat > "${PG_CONF_DIR}/pg_hba.conf" << EOL
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all            postgres                                peer
local   all            all                                     scram-sha-256
host    all            all             127.0.0.1/32            scram-sha-256
host    all            all             ::1/128                 scram-sha-256
host    all            all             0.0.0.0/0               scram-sha-256
EOL

    # Set proper permissions
    chown -R postgres:postgres "${PG_CONF_DIR}"
    chmod 700 "${PG_CONF_DIR}"
    chmod 600 "${PG_CONF_DIR}"/*
    
    # Start PostgreSQL
    systemctl restart postgresql
    systemctl enable postgresql
    
    # Wait for PostgreSQL to be ready
    for i in {1..30}; do
        if sudo -u postgres psql -c '\l' >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
}

# Setup database
setup_database() {
    log "Setting up database..."
    
    # Set postgres user password
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASS}';"
    
    # Create pgAdmin user
    sudo -u postgres psql -c "CREATE USER ${PGADMIN_USER} WITH PASSWORD '${PGADMIN_PASS}' SUPERUSER;"
    
    # Create application database and user
    sudo -u postgres psql << EOF
CREATE DATABASE ${DB_NAME};
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

    # Initialize database schema
    sudo -u postgres psql -d ${DB_NAME} -f /opt/talkgo/server/src/database/schema.sql
}

# Install Node.js and npm
install_nodejs() {
    log "Installing Node.js..."
    
    # Remove existing Node.js installations
    apt-get remove --purge -y nodejs npm
    rm -rf /usr/local/lib/node_modules
    rm -rf /usr/local/bin/node
    rm -rf /usr/local/bin/npm
    
    # Add NodeSource repository
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    
    # Install Node.js
    apt-get install -y nodejs
    
    # Install TypeScript globally
    npm install -g typescript
    
    # Verify installations
    node --version
    npm --version
    tsc --version
}

# Configure Nginx
setup_nginx() {
    log "Configuring Nginx..."
    
    # Install Nginx
    apt-get install -y nginx
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Create Nginx configuration
    cat > /etc/nginx/sites-available/talkgo << EOL
server {
    listen 80;
    server_name _;

    access_log /var/log/nginx/talkgo-access.log;
    error_log /var/log/nginx/talkgo-error.log;

    location / {
        proxy_pass http://localhost:4173;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api/ {
        proxy_pass http://localhost:8000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /socket.io/ {
        proxy_pass http://localhost:8001/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOL

    # Enable site
    ln -sf /etc/nginx/sites-available/talkgo /etc/nginx/sites-enabled/
    
    # Test and restart Nginx
    nginx -t
    systemctl restart nginx
}

# Copy project files
copy_project_files() {
    log "Copying project files..."
    
    # Create application directory
    mkdir -p /opt/talkgo
    
    # Copy frontend files
    cp -r * /opt/talkgo/
    
    # Create necessary directories
    mkdir -p /opt/talkgo/auth
    chmod 777 /opt/talkgo/auth
}

# Setup application
setup_application() {
    log "Setting up application..."
    
    cd /opt/talkgo || error "Failed to change directory"
    
    # Install frontend dependencies and build
    npm install
    npm run build
    
    # Setup backend
    cd server || error "Failed to change directory"
    npm install
}

# Setup systemd services
setup_services() {
    log "Setting up systemd services..."
    
    # Backend service
    cat > /etc/systemd/system/talkgo-backend.service << EOL
[Unit]
Description=TalkGo Backend Service
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/talkgo/server
Environment=NODE_ENV=production
Environment=PORT=8000
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Baileys service
    cat > /etc/systemd/system/talkgo-baileys.service << EOL
[Unit]
Description=TalkGo Baileys Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/talkgo/server
Environment=NODE_ENV=production
Environment=PORT=8001
ExecStart=/usr/bin/node src/baileys.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Frontend service
    cat > /etc/systemd/system/talkgo-frontend.service << EOL
[Unit]
Description=TalkGo Frontend Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/talkgo
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm run preview
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

    # Reload systemd and start services
    systemctl daemon-reload
    systemctl enable talkgo-backend talkgo-baileys talkgo-frontend
    systemctl start talkgo-backend talkgo-baileys talkgo-frontend
}

# Main installation function
main() {
    log "Starting TalkGo installation..."
    
    # Install system dependencies
    apt-get update && apt-get upgrade -y
    apt-get install -y curl git build-essential python3 python3-pip
    
    copy_project_files
    install_postgresql
    install_nodejs
    setup_database
    setup_nginx
    setup_application
    setup_services
    
    log "Installation completed successfully!"
    log "You can now access the application at: http://SERVER_IP"
    log ""
    log "Database credentials:"
    log "  Database: ${DB_NAME}"
    log "  User: ${DB_USER}"
    log "  Password: ${DB_PASS}"
    log ""
    log "Default admin credentials:"
    log "  Email: admin@sistema.com"
    log "  Password: admin123"
}

# Execute installation
main
