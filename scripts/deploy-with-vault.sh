#!/bin/bash
set -e

# Deploy script that retrieves Nomad token from Vault
# This script is used by GitHub Actions

VAULT_ADDR="${VAULT_ADDR:-https://vault.cloudya.net}"
VAULT_TOKEN="${VAULT_TOKEN}"

echo "🔐 Retrieving deployment credentials from Vault..."

# Function to get secret from Vault
get_vault_secret() {
    local path=$1
    local field=$2
    
    vault kv get -field="$field" "$path" 2>/dev/null || {
        echo "❌ Failed to retrieve $field from $path"
        return 1
    }
}

# Export Vault address and token
export VAULT_ADDR
export VAULT_TOKEN

# Get Nomad credentials from Vault
echo "Getting Nomad credentials..."
NOMAD_TOKEN=$(get_vault_secret "kv/data/traefik/nomad" "token")
NOMAD_ADDR=$(get_vault_secret "kv/data/traefik/nomad" "addr")

if [ -z "$NOMAD_TOKEN" ] || [ -z "$NOMAD_ADDR" ]; then
    echo "❌ Failed to retrieve Nomad credentials from Vault"
    echo "Please ensure:"
    echo "  1. Vault is accessible at $VAULT_ADDR"
    echo "  2. VAULT_TOKEN is valid"
    echo "  3. Secrets exist at kv/data/traefik/nomad"
    exit 1
fi

echo "✅ Retrieved Nomad credentials from Vault"

# Export for use in deployment
export NOMAD_TOKEN
export NOMAD_ADDR

echo "🚀 Deploying Traefik to Nomad..."

# The rest of deployment logic
echo "Nomad API endpoint: $NOMAD_ADDR"

# Check if running in GitHub Actions
if [ -n "$GITHUB_ACTIONS" ]; then
    echo "Running in GitHub Actions environment"
    
    # Install nomad CLI to convert HCL to JSON
    echo "Installing Nomad CLI..."
    curl -sL https://releases.hashicorp.com/nomad/1.7.2/nomad_1.7.2_linux_amd64.zip -o nomad.zip
    unzip -q nomad.zip
    chmod +x nomad
    
    # Convert HCL to JSON
    echo "Converting traefik.nomad to JSON..."
    ./nomad job run -output traefik.nomad > traefik.json
    
    # Submit job via Nomad API
    echo "Submitting job to Nomad..."
    RESPONSE=$(curl -X POST \
        -H "X-Nomad-Token: ${NOMAD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @traefik.json \
        "${NOMAD_ADDR}/v1/jobs" \
        -w "\n%{http_code}" -s)
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ Job submitted successfully"
        EVAL_ID=$(echo "$BODY" | jq -r .EvalID 2>/dev/null || echo "N/A")
        echo "Evaluation ID: $EVAL_ID"
        
        # Monitor deployment
        echo "Monitoring deployment status..."
        sleep 10
        
        # Check job status
        JOB_STATUS=$(curl -s -H "X-Nomad-Token: ${NOMAD_TOKEN}" \
            "${NOMAD_ADDR}/v1/job/traefik" | jq -r '.Status')
        
        echo "Job Status: $JOB_STATUS"
        
        if [ "$JOB_STATUS" = "running" ]; then
            echo "✅ Traefik is running!"
        else
            echo "⚠️ Traefik status: $JOB_STATUS"
        fi
    else
        echo "❌ Failed to submit job. HTTP Code: $HTTP_CODE"
        echo "Response: $BODY"
        exit 1
    fi
else
    echo "Running locally - using nomad CLI"
    nomad job run traefik.nomad
fi

echo ""
echo "========================================="
echo "✅ Deployment Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Verify SSL certificates: openssl s_client -connect traefik.cloudya.net:443"
echo "2. Check dashboard: https://traefik.cloudya.net"
echo "3. Monitor logs: nomad logs -f traefik"