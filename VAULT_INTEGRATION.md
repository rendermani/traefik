# Vault Integration for Traefik

This document describes how Traefik integrates with HashiCorp Vault for secure secret management.

## Overview

Traefik retrieves three types of secrets from Vault:
1. **Nomad Token** - For deployment automation
2. **Dashboard Credentials** - For Traefik dashboard authentication
3. **SSL Certificates** - For Let's Encrypt certificate storage

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   GitHub    │────▶│    Vault    │◀────│   Traefik   │
│   Actions   │     │   Secrets   │     │   Service   │
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                    ┌──────┴──────┐
                    │             │
              ┌─────▼─────┐ ┌────▼────┐
              │   Nomad   │ │  Certs  │
              │   Token   │ │ Storage │
              └───────────┘ └─────────┘
```

## Vault Paths

| Secret Type | Vault Path | Fields |
|------------|------------|---------|
| Nomad Credentials | `kv/data/traefik/nomad` | `token`, `addr` |
| Dashboard Auth | `kv/data/traefik/dashboard` | `username`, `password`, `auth` |
| SSL Certificates | `kv/data/traefik/certificates` | `storage_type`, `acme_email` |
| Vault Token | `kv/data/traefik/vault` | `token` |

## Setup Instructions

### 1. Initial Setup

Run the setup script to configure Vault:

```bash
./scripts/setup-vault-integration.sh
```

This script will:
- Create a Nomad management token
- Store it in Vault
- Generate dashboard credentials
- Configure SSL certificate storage
- Create Vault policy for Traefik
- Generate Vault token for Traefik service

### 2. Manual Setup (if needed)

#### Create Nomad Token
```bash
# SSH to server
nomad acl token create \
  -type="management" \
  -name="github-actions-traefik" \
  -global
```

#### Store in Vault
```bash
# Store Nomad token
vault kv put kv/data/traefik/nomad \
  token="YOUR_NOMAD_TOKEN" \
  addr="https://nomad.cloudya.net"

# Store dashboard credentials
vault kv put kv/data/traefik/dashboard \
  username="admin" \
  password="YOUR_PASSWORD" \
  auth="admin:\$2y\$10\$..."  # bcrypt hash

# Configure certificate storage
vault kv put kv/data/traefik/certificates \
  storage_type="vault" \
  acme_email="admin@cloudya.net"
```

### 3. GitHub Actions Configuration

Set these secrets in your GitHub repository:

| Secret Name | Value | Description |
|------------|-------|-------------|
| `VAULT_TOKEN` | Traefik service token | Token with read access to Vault |
| `VAULT_ADDR` | `https://vault.cloudya.net` | Vault server address |

The workflow will:
1. Try to connect to Vault
2. Retrieve Nomad credentials from Vault
3. Fall back to GitHub secrets if Vault is unavailable

## Vault Policy

The Traefik policy (`traefik-policy`) grants:

```hcl
# Read access to Traefik secrets
path "kv/data/traefik/*" {
  capabilities = ["read", "list"]
}

# Full access to certificate storage
path "kv/data/traefik/certificates/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Metadata access
path "kv/metadata/traefik/*" {
  capabilities = ["read", "list"]
}
```

## Nomad Job Integration

The Traefik Nomad job uses Vault templates to inject secrets:

```hcl
vault {
  policies = ["traefik-policy"]
  change_mode = "restart"
}

template {
  data = <<EOH
{{- with secret "kv/data/traefik/dashboard" }}
DASHBOARD_USER={{ .Data.data.username }}
DASHBOARD_PASS={{ .Data.data.password }}
DASHBOARD_AUTH={{ .Data.data.auth }}
{{- end }}
{{- with secret "kv/data/traefik/nomad" }}
NOMAD_TOKEN={{ .Data.data.token }}
NOMAD_ADDR={{ .Data.data.addr }}
{{- end }}
EOH
  destination = "secrets/env"
  env         = true
}
```

## Security Benefits

1. **No hardcoded secrets** - All sensitive data in Vault
2. **Rotation support** - Easy to rotate tokens and passwords
3. **Audit logging** - Vault logs all secret access
4. **Fine-grained access** - Policy-based permissions
5. **Centralized management** - Single source of truth

## Deployment Workflow

1. GitHub Actions triggers deployment
2. Workflow retrieves Vault token from GitHub secrets
3. Connects to Vault and fetches Nomad credentials
4. Deploys Traefik job to Nomad
5. Traefik starts and connects to Vault
6. Retrieves dashboard credentials and certificates
7. Configures authentication and SSL

## Troubleshooting

### Check Vault Connectivity
```bash
vault status
vault kv list kv/data/traefik
```

### Verify Secrets Exist
```bash
vault kv get kv/data/traefik/nomad
vault kv get kv/data/traefik/dashboard
```

### Test Nomad Token
```bash
NOMAD_TOKEN=$(vault kv get -field=token kv/data/traefik/nomad)
nomad status -token="$NOMAD_TOKEN"
```

### View Traefik Logs
```bash
nomad logs -f traefik
```

### Regenerate Vault Token
```bash
vault token create \
  -policy=traefik-policy \
  -period=768h
```

## Maintenance

### Rotate Nomad Token
1. Create new token: `nomad acl token create ...`
2. Update in Vault: `vault kv put kv/data/traefik/nomad token=NEW_TOKEN`
3. No deployment needed - GitHub Actions will use new token

### Change Dashboard Password
1. Generate new password and hash
2. Update in Vault: `vault kv put kv/data/traefik/dashboard ...`
3. Restart Traefik: `nomad job restart traefik`

### Renew Vault Token
1. Check expiry: `vault token lookup`
2. Renew: `vault token renew`
3. Or create new: `vault token create -policy=traefik-policy`
4. Update GitHub secret: `VAULT_TOKEN`

## Next Steps

1. Enable Vault audit logging
2. Set up automatic token renewal
3. Implement certificate backup to Vault
4. Add monitoring for secret expiry
5. Configure Vault auto-unseal