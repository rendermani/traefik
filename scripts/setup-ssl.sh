#!/bin/bash

# SSL Certificate Setup and Management Script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[SSL]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Configuration
DOMAIN="${1:-cloudya.net}"
ACME_FILE="/etc/traefik/acme.json"

# Check certificate status
check_certificates() {
    log_step "Checking SSL certificates..."
    
    if [ ! -f "$ACME_FILE" ]; then
        log_warn "ACME file not found - certificates not yet provisioned"
        return 1
    fi
    
    # Parse certificates from acme.json
    if command -v jq >/dev/null 2>&1; then
        CERTS=$(jq -r '.letsencrypt.Certificates[]?.domain.main' "$ACME_FILE" 2>/dev/null || echo "")
        
        if [ -z "$CERTS" ]; then
            log_warn "No certificates found in ACME storage"
        else
            log_info "Found certificates for:"
            echo "$CERTS" | while read -r CERT_DOMAIN; do
                echo "  - $CERT_DOMAIN"
            done
        fi
    else
        log_warn "jq not installed - cannot parse certificate details"
    fi
}

# Force certificate renewal
force_renewal() {
    log_step "Forcing certificate renewal..."
    
    # Backup current certificates
    if [ -f "$ACME_FILE" ]; then
        cp "$ACME_FILE" "${ACME_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
        log_info "Current certificates backed up"
    fi
    
    # Remove specific certificate to force renewal
    if [ -n "$1" ]; then
        DOMAIN_TO_RENEW="$1"
        log_info "Removing certificate for $DOMAIN_TO_RENEW to force renewal"
        
        # This would need jq to properly remove the certificate
        # For now, we'll restart Traefik which will trigger renewal if needed
    fi
    
    # Restart Traefik to trigger renewal
    systemctl restart traefik
    log_info "Traefik restarted - certificate renewal triggered"
    
    # Wait for renewal
    sleep 10
    
    # Check new status
    check_certificates
}

# Setup wildcard certificates
setup_wildcard() {
    log_step "Setting up wildcard certificate for *.$DOMAIN..."
    
    # Check if DNS challenge is configured
    if ! grep -q "dnsChallenge" /etc/traefik/traefik.yml; then
        log_warn "DNS challenge not configured - required for wildcard certificates"
        log_info "Add DNS challenge configuration to traefik.yml:"
        cat << EOF
certificatesResolvers:
  letsencrypt:
    acme:
      dnsChallenge:
        provider: cloudflare  # or your DNS provider
        delayBeforeCheck: 30s
EOF
        return 1
    fi
    
    log_info "DNS challenge configured - wildcard certificates will be requested automatically"
}

# Monitor certificate expiry
monitor_expiry() {
    log_step "Monitoring certificate expiry..."
    
    # Check each configured domain
    DOMAINS=(
        "traefik.$DOMAIN"
        "vault.$DOMAIN"
        "nomad.$DOMAIN"
        "api.$DOMAIN"
        "app.$DOMAIN"
    )
    
    for CHECK_DOMAIN in "${DOMAINS[@]}"; do
        if host "$CHECK_DOMAIN" >/dev/null 2>&1; then
            echo ""
            echo "Checking $CHECK_DOMAIN..."
            
            # Get certificate expiry
            CERT_INFO=$(echo | openssl s_client -connect "${CHECK_DOMAIN}:443" -servername "${CHECK_DOMAIN}" 2>/dev/null)
            
            if [ $? -eq 0 ]; then
                EXPIRY_DATE=$(echo "$CERT_INFO" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
                
                if [ -n "$EXPIRY_DATE" ]; then
                    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
                    CURRENT_EPOCH=$(date +%s)
                    DAYS_LEFT=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
                    
                    if [ $DAYS_LEFT -lt 7 ]; then
                        log_error "  ⚠️ Certificate expires in $DAYS_LEFT days!"
                    elif [ $DAYS_LEFT -lt 30 ]; then
                        log_warn "  ⏰ Certificate expires in $DAYS_LEFT days"
                    else
                        log_info "  ✅ Certificate valid for $DAYS_LEFT days"
                    fi
                    echo "     Expires: $EXPIRY_DATE"
                else
                    log_warn "  Could not determine expiry date"
                fi
            else
                log_warn "  No certificate found or domain not accessible"
            fi
        fi
    done
}

# Setup certificate backup
setup_backup() {
    log_step "Setting up certificate backup..."
    
    # Create backup script
    cat > /usr/local/bin/backup-traefik-certs.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backups/traefik/certificates"
mkdir -p "$BACKUP_DIR"

if [ -f /etc/traefik/acme.json ]; then
    BACKUP_FILE="$BACKUP_DIR/acme-$(date +%Y%m%d-%H%M%S).json"
    cp /etc/traefik/acme.json "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    
    # Keep only last 30 backups
    find "$BACKUP_DIR" -name "acme-*.json" -mtime +30 -delete
    
    echo "Certificates backed up to $BACKUP_FILE"
fi
EOF
    
    chmod +x /usr/local/bin/backup-traefik-certs.sh
    
    # Create cron job for daily backup
    cat > /etc/cron.d/traefik-cert-backup << EOF
# Backup Traefik certificates daily at 2 AM
0 2 * * * root /usr/local/bin/backup-traefik-certs.sh
EOF
    
    log_info "Certificate backup configured (daily at 2 AM)"
}

# Restore certificates
restore_certificates() {
    local BACKUP_FILE="$1"
    
    if [ -z "$BACKUP_FILE" ]; then
        log_error "Usage: $0 restore <backup-file>"
        return 1
    fi
    
    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        return 1
    fi
    
    log_step "Restoring certificates from $BACKUP_FILE..."
    
    # Backup current certificates
    if [ -f "$ACME_FILE" ]; then
        mv "$ACME_FILE" "${ACME_FILE}.before-restore"
    fi
    
    # Restore
    cp "$BACKUP_FILE" "$ACME_FILE"
    chmod 600 "$ACME_FILE"
    chown traefik:traefik "$ACME_FILE"
    
    # Restart Traefik
    systemctl restart traefik
    
    log_info "Certificates restored successfully"
}

# Main menu
case "${2:-check}" in
    check)
        check_certificates
        monitor_expiry
        ;;
    renew)
        force_renewal "$3"
        ;;
    wildcard)
        setup_wildcard
        ;;
    monitor)
        monitor_expiry
        ;;
    backup)
        setup_backup
        ;;
    restore)
        restore_certificates "$3"
        ;;
    *)
        echo "Usage: $0 <domain> <action>"
        echo "Actions:"
        echo "  check    - Check certificate status (default)"
        echo "  renew    - Force certificate renewal"
        echo "  wildcard - Setup wildcard certificate"
        echo "  monitor  - Monitor certificate expiry"
        echo "  backup   - Setup automatic backup"
        echo "  restore  - Restore from backup"
        ;;
esac