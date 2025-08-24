#!/bin/bash
set -e

# Vault Integration Setup for Traefik
# This script configures Vault to store Traefik secrets

VAULT_ADDR="${VAULT_ADDR:-https://vault.cloudya.net}"
VAULT_TOKEN="${VAULT_TOKEN}"

echo "🔐 Setting up Vault integration for Traefik..."

# Function to check Vault connectivity
check_vault() {
    echo "Checking Vault connectivity..."
    if vault status >/dev/null 2>&1; then
        echo "✅ Vault is accessible"
    else
        echo "❌ Cannot connect to Vault at $VAULT_ADDR"
        exit 1
    fi
}

# Function to create Nomad management token
create_nomad_token() {
    echo "📝 Creating Nomad management token..."
    
    # Check if Nomad is running
    if ! nomad status >/dev/null 2>&1; then
        echo "❌ Nomad is not accessible"
        return 1
    fi
    
    # Create management token for GitHub Actions
    NOMAD_TOKEN=$(nomad acl token create \
        -type="management" \
        -name="github-actions-traefik" \
        -global \
        -format=json | jq -r '.SecretID')
    
    if [ -z "$NOMAD_TOKEN" ]; then
        echo "❌ Failed to create Nomad token"
        return 1
    fi
    
    echo "✅ Nomad token created successfully"
    echo "$NOMAD_TOKEN"
}

# Function to store secrets in Vault
store_in_vault() {
    local path=$1
    local key=$2
    local value=$3
    
    echo "Storing $key in Vault at $path..."
    
    vault kv put "$path" "$key=$value" >/dev/null 2>&1 || {
        # If path doesn't exist, create it
        vault kv put "$path" "$key=$value"
    }
    
    echo "✅ Stored $key in Vault"
}

# Main setup process
main() {
    # Check prerequisites
    check_vault
    
    # 1. Create and store Nomad token
    echo ""
    echo "1️⃣ Nomad Token Setup"
    echo "===================="
    
    # Try to get existing token or create new one
    EXISTING_TOKEN=$(vault kv get -field=token kv/data/traefik/nomad 2>/dev/null || echo "")
    
    if [ -z "$EXISTING_TOKEN" ]; then
        echo "No existing Nomad token found in Vault, creating new one..."
        NOMAD_TOKEN=$(create_nomad_token)
        
        if [ ! -z "$NOMAD_TOKEN" ]; then
            store_in_vault "kv/data/traefik/nomad" "token" "$NOMAD_TOKEN"
            store_in_vault "kv/data/traefik/nomad" "addr" "https://nomad.cloudya.net"
        else
            echo "⚠️ Could not create Nomad token automatically"
            echo "Please create manually and store in Vault"
        fi
    else
        echo "✅ Nomad token already exists in Vault"
    fi
    
    # 2. Store dashboard credentials
    echo ""
    echo "2️⃣ Dashboard Credentials Setup"
    echo "=============================="
    
    # Check if credentials exist
    EXISTING_USER=$(vault kv get -field=username kv/data/traefik/dashboard 2>/dev/null || echo "")
    
    if [ -z "$EXISTING_USER" ]; then
        echo "Setting up dashboard credentials..."
        
        # Generate secure password
        DASHBOARD_USER="admin"
        DASHBOARD_PASS=$(openssl rand -base64 32)
        
        store_in_vault "kv/data/traefik/dashboard" "username" "$DASHBOARD_USER"
        store_in_vault "kv/data/traefik/dashboard" "password" "$DASHBOARD_PASS"
        
        # Also store bcrypt hash for Traefik
        DASHBOARD_HASH=$(htpasswd -nbB "$DASHBOARD_USER" "$DASHBOARD_PASS" | sed -e s/\\$/\\$\\$/g)
        store_in_vault "kv/data/traefik/dashboard" "auth" "$DASHBOARD_HASH"
        
        echo ""
        echo "📋 Dashboard Credentials:"
        echo "   Username: $DASHBOARD_USER"
        echo "   Password: $DASHBOARD_PASS"
        echo "   (Stored in Vault at kv/data/traefik/dashboard)"
    else
        echo "✅ Dashboard credentials already exist in Vault"
    fi
    
    # 3. Configure SSL certificate storage
    echo ""
    echo "3️⃣ SSL Certificate Storage Setup"
    echo "================================"
    
    # Create path for certificates
    vault kv put kv/data/traefik/certificates \
        storage_type="vault" \
        acme_email="admin@cloudya.net" \
        created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
    
    echo "✅ SSL certificate storage configured in Vault"
    
    # 4. Create Vault policy for Traefik
    echo ""
    echo "4️⃣ Vault Policy Setup"
    echo "===================="
    
    cat > /tmp/traefik-vault-policy.hcl <<EOF
# Traefik Vault Policy
path "kv/data/traefik/*" {
  capabilities = ["read", "list"]
}

path "kv/data/traefik/certificates/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/traefik/*" {
  capabilities = ["read", "list"]
}
EOF
    
    vault policy write traefik-policy /tmp/traefik-vault-policy.hcl
    echo "✅ Vault policy created for Traefik"
    
    # 5. Create Vault token for Traefik
    echo ""
    echo "5️⃣ Creating Vault Token for Traefik"
    echo "===================================="
    
    TRAEFIK_VAULT_TOKEN=$(vault token create \
        -policy=traefik-policy \
        -period=768h \
        -format=json | jq -r '.auth.client_token')
    
    store_in_vault "kv/data/traefik/vault" "token" "$TRAEFIK_VAULT_TOKEN"
    
    echo "✅ Vault token created for Traefik service"
    
    # 6. Summary
    echo ""
    echo "========================================="
    echo "✅ Vault Integration Setup Complete!"
    echo "========================================="
    echo ""
    echo "Secrets stored in Vault:"
    echo "  • Nomad Token: kv/data/traefik/nomad"
    echo "  • Dashboard: kv/data/traefik/dashboard"
    echo "  • Certificates: kv/data/traefik/certificates"
    echo "  • Vault Token: kv/data/traefik/vault"
    echo ""
    echo "Next steps:"
    echo "1. Update GitHub secret VAULT_TOKEN with the Traefik token"
    echo "2. Deploy Traefik using the updated configuration"
    echo "3. Verify SSL certificates are working"
}

# Run main function
main "$@"