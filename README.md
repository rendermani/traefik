# Traefik Repository

Edge router and reverse proxy for all services with automatic SSL/TLS termination.

## Overview

This repository contains the infrastructure code for deploying Traefik as the foundation reverse proxy with:
- Automatic SSL/TLS with Let's Encrypt
- Service discovery and dynamic routing
- Security middleware and rate limiting
- Dashboard with authentication
- Integration with Vault for certificate storage
- Auto-detection of backend services

## Repository Structure

```
traefik/
├── .github/
│   └── workflows/
│       └── deploy.yml         # Deployment workflow
├── config/
│   ├── traefik.yml           # Static configuration
│   └── dynamic/              # Dynamic configurations
│       ├── services.yml      # Service definitions
│       ├── routers.yml       # Routing rules
│       └── middlewares.yml   # Security middleware
├── scripts/
│   ├── deploy-traefik.sh     # Main deployment script
│   ├── setup-ssl.sh          # SSL certificate setup
│   └── check-services.sh     # Service discovery
├── certs/                    # SSL certificates (gitignored)
└── tests/                    # Integration tests
```

## Quick Start

### Deployment via GitHub Actions

1. Go to Actions tab
2. Select "Deploy Traefik"
3. Run workflow with desired action:
   - `install` - Fresh installation
   - `upgrade` - Upgrade Traefik version
   - `configure` - Update configuration
   - `restart` - Restart service

### Manual Deployment

```bash
# Clone repository
git clone https://github.com/rendermani/traefik.git
cd traefik

# Deploy to server
./scripts/deploy-traefik.sh --environment production --action install
```

## Services Routing

Traefik automatically configures routing for:

| Service | Domain | Backend |
|---------|--------|---------|
| Vault | vault.cloudya.net | http://localhost:8200 |
| Nomad | nomad.cloudya.net | http://localhost:4646 |
| Prometheus | metrics.cloudya.net | http://localhost:9090 |
| Grafana | grafana.cloudya.net | http://localhost:3000 |
| Loki | logs.cloudya.net | http://localhost:3100 |
| Traefik Dashboard | traefik.cloudya.net | Internal |

## SSL/TLS Configuration

Traefik uses Let's Encrypt for automatic SSL certificates:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@cloudya.net
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
```

## Security Features

### Middleware Stack

- **Security Headers**: HSTS, CSP, X-Frame-Options
- **Rate Limiting**: Configurable per service
- **IP Whitelist**: Optional restriction
- **Basic Auth**: For admin interfaces
- **CORS**: Configurable per service

### Authentication

Dashboard and admin interfaces use:
1. Basic authentication (initial setup)
2. Vault-based authentication (when available)
3. Forward auth to external IdP (optional)

## Auto-Detection

Traefik automatically detects and configures routing for:
- Services registered in Nomad
- Services with health endpoints
- Docker containers with labels

## Integration with Vault

When Vault is available:
- Stores SSL certificates in Vault
- Uses Vault for authentication secrets
- Rotates credentials automatically

## Integration with Nomad

When Nomad is available:
- Discovers services via Nomad API
- Updates routing dynamically
- Handles service scaling

## Monitoring

Traefik exposes metrics at `/metrics` for Prometheus:
- Request rates and latencies
- Error rates by service
- SSL certificate expiry
- Backend health status

## Configuration

### Environment Variables

```bash
# Domain configuration
BASE_DOMAIN=cloudya.net
ACME_EMAIL=admin@cloudya.net

# Dashboard authentication
DASHBOARD_USER=admin
DASHBOARD_PASSWORD=secure-password

# Let's Encrypt
ACME_STAGING=false  # Use true for testing

# Service discovery
ENABLE_NOMAD_PROVIDER=true
ENABLE_DOCKER_PROVIDER=false
```

### Dynamic Configuration

Services can be added dynamically via:
1. File provider (config/dynamic/)
2. Nomad provider (auto-discovery)
3. Docker provider (container labels)

## Backup and Recovery

```bash
# Backup configuration and certificates
./scripts/backup-traefik.sh

# Restore from backup
./scripts/restore-traefik.sh /backups/traefik/20250124-123456
```

## Troubleshooting

### Check Service Health
```bash
curl -s http://localhost:8080/api/http/services | jq
```

### View Access Logs
```bash
journalctl -u traefik -f
```

### SSL Certificate Issues
```bash
# Check certificate status
./scripts/check-certificates.sh

# Force renewal
./scripts/renew-certificates.sh
```

## Dependencies

- Traefik 3.0+
- systemd
- Let's Encrypt account
- Valid DNS for domains

## Related Repositories

- [rendermani/vault](https://github.com/rendermani/vault) - Secret management
- [rendermani/nomad](https://github.com/rendermani/nomad) - Container orchestration
- [rendermani/monitoring](https://github.com/rendermani/monitoring) - Observability stack

## Security Considerations

- Never commit acme.json or certificates
- Keep dashboard authentication strong
- Regularly update Traefik version
- Monitor SSL certificate expiry
- Review access logs regularly# Trigger deploy
