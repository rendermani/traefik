#!/bin/bash

set -e

# Traefik deployment script with auto-detection
# Standalone deployment that discovers services automatically

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
ENVIRONMENT=""
ACTION="install"
TRAEFIK_VERSION="3.2.3"
DOMAIN="cloudya.net"
ACME_EMAIL="admin@cloudya.net"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --action)
            ACTION="$2"
            shift 2
            ;;
        --version)
            TRAEFIK_VERSION="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --email)
            ACME_EMAIL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_info() { echo -e "${GREEN}[TRAEFIK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Check Traefik status
check_traefik() {
    if systemctl list-units --all | grep -q traefik.service; then
        if systemctl is-active traefik >/dev/null 2>&1; then
            CURRENT_VERSION=$(traefik version 2>/dev/null | grep -oP 'Version:\s*\K[0-9.]+' || echo "unknown")
            echo "exists:running:${CURRENT_VERSION}"
        else
            echo "exists:stopped:unknown"
        fi
    else
        echo "not-exists:none:none"
    fi
}

# Detect available services
detect_services() {
    log_step "Detecting available services..."
    
    SERVICES=()
    
    # Check Vault
    if curl -f -s --max-time 2 http://localhost:8200/v1/sys/health >/dev/null 2>&1; then
        SERVICES+=("vault:8200")
        log_info "✅ Vault detected on port 8200"
    fi
    
    # Check Nomad
    if curl -f -s --max-time 2 http://localhost:4646/v1/status/leader >/dev/null 2>&1; then
        SERVICES+=("nomad:4646")
        log_info "✅ Nomad detected on port 4646"
    fi
    
    # Check Prometheus
    if curl -f -s --max-time 2 http://localhost:9090/-/healthy >/dev/null 2>&1; then
        SERVICES+=("prometheus:9090")
        log_info "✅ Prometheus detected on port 9090"
    fi
    
    # Check Grafana
    if curl -f -s --max-time 2 http://localhost:3000/api/health >/dev/null 2>&1; then
        SERVICES+=("grafana:3000")
        log_info "✅ Grafana detected on port 3000"
    fi
    
    # Check Loki
    if curl -f -s --max-time 2 http://localhost:3100/ready >/dev/null 2>&1; then
        SERVICES+=("loki:3100")
        log_info "✅ Loki detected on port 3100"
    fi
    
    # Check MinIO
    if curl -f -s --max-time 2 http://localhost:9000/minio/health/live >/dev/null 2>&1; then
        SERVICES+=("minio:9000")
        log_info "✅ MinIO detected on port 9000"
    fi
    
    # Check application backend
    if curl -f -s --max-time 2 http://localhost:8000/health >/dev/null 2>&1; then
        SERVICES+=("backend:8000")
        log_info "✅ Backend API detected on port 8000"
    fi
    
    # Check application frontend
    if curl -f -s --max-time 2 http://localhost:3001/ >/dev/null 2>&1; then
        SERVICES+=("frontend:3001")
        log_info "✅ Frontend detected on port 3001"
    fi
    
    if [ ${#SERVICES[@]} -eq 0 ]; then
        log_warn "No services detected - Traefik will run with default configuration"
    fi
}

# Backup Traefik
backup_traefik() {
    log_step "Creating Traefik backup..."
    
    BACKUP_DIR="/backups/traefik/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Backup configuration
    if [ -d /etc/traefik ]; then
        tar -czf "$BACKUP_DIR/traefik-config.tar.gz" /etc/traefik/ 2>/dev/null || true
    fi
    
    # Backup ACME certificates
    if [ -f /etc/traefik/acme.json ]; then
        cp /etc/traefik/acme.json "$BACKUP_DIR/acme.json"
        chmod 600 "$BACKUP_DIR/acme.json"
    fi
    
    log_info "Backup created: $BACKUP_DIR"
}

# Install Traefik
install_traefik() {
    local TRAEFIK_STATE=$(check_traefik)
    IFS=':' read -r EXISTS STATUS VERSION <<< "$TRAEFIK_STATE"
    
    if [[ "$EXISTS" == "exists" && "$VERSION" == "$TRAEFIK_VERSION" ]]; then
        log_info "Traefik $TRAEFIK_VERSION already installed"
        return 0
    fi
    
    if [[ "$EXISTS" == "exists" ]]; then
        log_step "Upgrading Traefik from $VERSION to $TRAEFIK_VERSION..."
        backup_traefik
        systemctl stop traefik
    else
        log_step "Installing Traefik $TRAEFIK_VERSION..."
    fi
    
    # Download and install
    cd /tmp
    wget -q "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
    tar -xzf "traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
    mv traefik /usr/local/bin/
    chmod +x /usr/local/bin/traefik
    rm "traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz"
    
    # Create user and directories
    if ! id -u traefik >/dev/null 2>&1; then
        useradd --system --home /var/lib/traefik --shell /bin/false traefik
    fi
    
    mkdir -p /etc/traefik/dynamic /var/lib/traefik /var/log/traefik
    chown -R traefik:traefik /etc/traefik /var/lib/traefik /var/log/traefik
    
    log_info "Traefik $TRAEFIK_VERSION installed successfully"
}

# Configure Traefik
configure_traefik() {
    log_step "Configuring Traefik..."
    
    # Detect services first
    detect_services
    
    # Create main configuration
    cat > /etc/traefik/traefik.yml << EOF
# Traefik Static Configuration
api:
  dashboard: true
  debug: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt
  
  metrics:
    address: ":8082"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ACME_EMAIL}
      storage: /etc/traefik/acme.json
      keyType: EC256
      httpChallenge:
        entryPoint: web

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
  format: json

metrics:
  prometheus:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    entryPoint: metrics

ping:
  entryPoint: web
EOF
    
    # Add Nomad provider if detected
    if [[ " ${SERVICES[@]} " =~ " nomad:4646 " ]]; then
        cat >> /etc/traefik/traefik.yml << EOF

providers:
  nomad:
    endpoint:
      address: http://localhost:4646
    prefix: traefik
    exposedByDefault: false
    refreshInterval: 30s
EOF
    fi
    
    # Generate admin password
    ADMIN_PASSWORD=$(openssl rand -base64 32)
    ADMIN_HASH=$(htpasswd -nbB admin "$ADMIN_PASSWORD" | sed -e s/\\$/\\$\\$/g)
    
    # Save password for user
    echo "Traefik Dashboard Credentials:" > /root/traefik-credentials.txt
    echo "Username: admin" >> /root/traefik-credentials.txt
    echo "Password: $ADMIN_PASSWORD" >> /root/traefik-credentials.txt
    echo "URL: https://traefik.${DOMAIN}" >> /root/traefik-credentials.txt
    chmod 600 /root/traefik-credentials.txt
    
    # Create dynamic configuration files
    mkdir -p /etc/traefik/dynamic
    
    # Services configuration
    cat > /etc/traefik/dynamic/services.yml << EOF
http:
  services:
EOF
    
    # Add detected services
    for SERVICE in "${SERVICES[@]}"; do
        IFS=':' read -r NAME PORT <<< "$SERVICE"
        cat >> /etc/traefik/dynamic/services.yml << EOF
    ${NAME}:
      loadBalancer:
        servers:
          - url: "http://localhost:${PORT}"
EOF
    done
    
    # Routers configuration
    cat > /etc/traefik/dynamic/routers.yml << EOF
http:
  routers:
    traefik-dashboard:
      rule: "Host(\`traefik.${DOMAIN}\`)"
      service: api@internal
      middlewares:
        - auth-dashboard
        - security-headers
      tls:
        certResolver: letsencrypt
EOF
    
    # Add routers for detected services
    for SERVICE in "${SERVICES[@]}"; do
        IFS=':' read -r NAME PORT <<< "$SERVICE"
        
        # Determine subdomain
        case $NAME in
            vault) SUBDOMAIN="vault" ;;
            nomad) SUBDOMAIN="nomad" ;;
            prometheus) SUBDOMAIN="metrics" ;;
            grafana) SUBDOMAIN="grafana" ;;
            loki) SUBDOMAIN="logs" ;;
            minio) SUBDOMAIN="storage" ;;
            backend) SUBDOMAIN="api" ;;
            frontend) SUBDOMAIN="app" ;;
            *) SUBDOMAIN="$NAME" ;;
        esac
        
        cat >> /etc/traefik/dynamic/routers.yml << EOF
    
    ${NAME}:
      rule: "Host(\`${SUBDOMAIN}.${DOMAIN}\`)"
      service: ${NAME}
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt
EOF
    done
    
    # Middleware configuration
    cat > /etc/traefik/dynamic/middlewares.yml << EOF
http:
  middlewares:
    auth-dashboard:
      basicAuth:
        users:
          - "${ADMIN_HASH}"
    
    security-headers:
      headers:
        frameDeny: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: "SAMEORIGIN"
        referrerPolicy: "strict-origin-when-cross-origin"
    
    rate-limit:
      rateLimit:
        average: 100
        burst: 200
        period: 1m
EOF
    
    # Create ACME storage
    touch /etc/traefik/acme.json
    chmod 600 /etc/traefik/acme.json
    chown traefik:traefik /etc/traefik/acme.json
    
    # Create systemd service
    cat > /etc/systemd/system/traefik.service << 'EOF'
[Unit]
Description=Traefik Edge Router
Documentation=https://doc.traefik.io/traefik/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=traefik
Group=traefik
ExecStart=/usr/local/bin/traefik --configfile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=traefik
KillMode=process
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start Traefik
    systemctl daemon-reload
    systemctl enable traefik
    systemctl restart traefik
    
    log_info "✅ Traefik configured successfully"
    log_info "📝 Dashboard credentials saved to /root/traefik-credentials.txt"
}

# Setup automatic service discovery
setup_auto_discovery() {
    log_step "Setting up automatic service discovery..."
    
    # Create discovery script
    cat > /usr/local/bin/traefik-discover-services.sh << 'EOF'
#!/bin/bash

# Auto-discover services and update Traefik configuration

SERVICES_FILE="/etc/traefik/dynamic/auto-discovered.yml"
TEMP_FILE="/tmp/traefik-services-temp.yml"

# Start with empty services
echo "http:" > "$TEMP_FILE"
echo "  services:" >> "$TEMP_FILE"

# Check common services
declare -A SERVICE_CHECKS=(
    ["vault"]="8200:/v1/sys/health"
    ["nomad"]="4646:/v1/status/leader"
    ["prometheus"]="9090:/-/healthy"
    ["grafana"]="3000:/api/health"
    ["loki"]="3100:/ready"
    ["minio"]="9000:/minio/health/live"
    ["backend"]="8000:/health"
    ["frontend"]="3001:/"
)

for SERVICE in "${!SERVICE_CHECKS[@]}"; do
    IFS=':' read -r PORT PATH <<< "${SERVICE_CHECKS[$SERVICE]}"
    
    if curl -f -s --max-time 2 "http://localhost:${PORT}${PATH}" >/dev/null 2>&1; then
        cat >> "$TEMP_FILE" << EOF
    ${SERVICE}-auto:
      loadBalancer:
        servers:
          - url: "http://localhost:${PORT}"
EOF
    fi
done

# Only update if changed
if [ -f "$SERVICES_FILE" ]; then
    if ! diff -q "$TEMP_FILE" "$SERVICES_FILE" >/dev/null 2>&1; then
        mv "$TEMP_FILE" "$SERVICES_FILE"
        echo "Services updated: $(date)"
    else
        rm "$TEMP_FILE"
    fi
else
    mv "$TEMP_FILE" "$SERVICES_FILE"
    echo "Services discovered: $(date)"
fi
EOF
    
    chmod +x /usr/local/bin/traefik-discover-services.sh
    
    # Create systemd timer for auto-discovery
    cat > /etc/systemd/system/traefik-discovery.service << 'EOF'
[Unit]
Description=Traefik Service Discovery
After=traefik.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/traefik-discover-services.sh
User=traefik
Group=traefik
EOF
    
    cat > /etc/systemd/system/traefik-discovery.timer << 'EOF'
[Unit]
Description=Run Traefik Service Discovery every minute
Requires=traefik-discovery.service

[Timer]
OnCalendar=*:0/1
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Enable auto-discovery
    systemctl daemon-reload
    systemctl enable traefik-discovery.timer
    systemctl start traefik-discovery.timer
    
    log_info "✅ Auto-discovery configured"
}

# Main execution
case "$ACTION" in
    check)
        STATE=$(check_traefik)
        log_info "Traefik state: $STATE"
        detect_services
        ;;
    install)
        install_traefik
        configure_traefik
        setup_auto_discovery
        ;;
    upgrade)
        install_traefik
        ;;
    configure)
        configure_traefik
        setup_auto_discovery
        ;;
    backup)
        backup_traefik
        ;;
    restart)
        systemctl restart traefik
        log_info "Traefik restarted"
        ;;
    *)
        log_error "Unknown action: $ACTION"
        exit 1
        ;;
esac

# Final health check
log_step "Health check..."
sleep 5

if curl -f -s http://localhost:80/ping >/dev/null 2>&1; then
    log_info "✅ Traefik is healthy"
    
    # Show running configuration
    echo ""
    log_info "📊 Traefik Status:"
    echo "  - Dashboard: https://traefik.${DOMAIN}"
    echo "  - Metrics: http://localhost:8082/metrics"
    
    # Show detected routes
    if [ ${#SERVICES[@]} -gt 0 ]; then
        echo ""
        log_info "🔗 Configured Routes:"
        for SERVICE in "${SERVICES[@]}"; do
            IFS=':' read -r NAME PORT <<< "$SERVICE"
            case $NAME in
                vault) echo "  - https://vault.${DOMAIN}" ;;
                nomad) echo "  - https://nomad.${DOMAIN}" ;;
                prometheus) echo "  - https://metrics.${DOMAIN}" ;;
                grafana) echo "  - https://grafana.${DOMAIN}" ;;
                loki) echo "  - https://logs.${DOMAIN}" ;;
                minio) echo "  - https://storage.${DOMAIN}" ;;
                backend) echo "  - https://api.${DOMAIN}" ;;
                frontend) echo "  - https://app.${DOMAIN}" ;;
            esac
        done
    fi
else
    log_error "❌ Traefik health check failed"
    journalctl -u traefik -n 50 --no-pager
    exit 1
fi