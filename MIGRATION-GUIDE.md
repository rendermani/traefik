# Traefik Migration Guide: Systemd to Nomad

## Pre-Migration Checklist

### Prerequisites
- [ ] Nomad is running on the server
- [ ] Docker is available and running
- [ ] Current Traefik is healthy
- [ ] Backup storage available (min 1GB)
- [ ] Maintenance window scheduled (optional)
- [ ] Team notified of migration

### Access Requirements
- [ ] SSH access to server
- [ ] Nomad UI access (optional)
- [ ] Traefik dashboard credentials

## Migration Steps

### Step 1: Pre-Migration Check
```bash
# SSH to server
ssh root@cloudya.net

# Check current state
systemctl status traefik
curl -s http://localhost/ping

# Check Nomad status
nomad status
nomad node status
```

### Step 2: Deploy Migration Scripts
```bash
# Copy migration script to server
cd traefik
scp scripts/migrate-to-nomad.sh root@cloudya.net:/tmp/

# Copy Nomad job file
scp ../nomad/jobs/infrastructure/traefik.nomad root@cloudya.net:/tmp/

# SSH to server
ssh root@cloudya.net

# Make script executable
chmod +x /tmp/migrate-to-nomad.sh
```

### Step 3: Run Pre-Migration Check
```bash
# Check prerequisites
/tmp/migrate-to-nomad.sh check

# Expected output:
# ✅ Traefik running via systemd
# ✅ Nomad is running
# ✅ Certificate file found
# Current deployment mode: systemd
```

### Step 4: Prepare Environment
```bash
# Create required directories and backup
/tmp/migrate-to-nomad.sh prepare

# This will:
# - Create backup in /backups/traefik/
# - Set up /opt/traefik/ directories
# - Copy configurations
# - Preserve certificates
```

### Step 5: Deploy to Nomad (Parallel)
```bash
# Deploy Traefik to Nomad without stopping systemd
/tmp/migrate-to-nomad.sh deploy-only

# Check Nomad deployment
nomad job status traefik
nomad alloc logs <alloc-id>

# Verify parallel operation
curl -s http://localhost:8080/ping  # Nomad Traefik
curl -s http://localhost/ping       # Systemd Traefik
```

### Step 6: Perform Cutover
```bash
# ⚠️ This is the critical step - traffic will switch

# Execute cutover
/tmp/migrate-to-nomad.sh cutover

# This will:
# 1. Stop systemd Traefik
# 2. Nomad Traefik takes over ports 80/443
# 3. Verify health checks
# 4. Auto-rollback if failed
```

### Step 7: Verify Migration
```bash
# Run verification suite
/tmp/migrate-to-nomad.sh verify

# Manual checks
curl -I https://traefik.cloudya.net
curl -I https://vault.cloudya.net
curl -I https://nomad.cloudya.net
curl -I https://api.cloudya.net

# Check certificate status
ls -la /opt/traefik/acme/acme.json

# Check Nomad allocation
nomad alloc status <alloc-id>
```

### Step 8: Monitor
```bash
# Watch logs
nomad alloc logs -f <alloc-id>

# Monitor metrics
curl -s http://localhost:8082/metrics | grep traefik_

# Check service discovery
nomad job status traefik
```

## Rollback Procedure

### If Issues Occur
```bash
# Immediate rollback
/tmp/migrate-to-nomad.sh rollback

# This will:
# 1. Stop Nomad job
# 2. Start systemd service
# 3. Restore original configuration
# 4. Verify operation

# Manual rollback if script fails
nomad job stop traefik
systemctl start traefik
systemctl enable traefik
```

## Post-Migration

### After Successful Migration
```bash
# Clean up old systemd files (after 24h stability)
/tmp/migrate-to-nomad.sh cleanup

# Update monitoring
# - Update dashboard links
# - Update alert rules
# - Update documentation
```

### Configuration Management

#### Update Traefik via Nomad
```bash
# Edit job file
vi /opt/nomad/jobs/traefik.nomad

# Deploy update
nomad job run /opt/nomad/jobs/traefik.nomad

# Monitor deployment
nomad job status traefik
```

#### Certificate Management
```bash
# Certificates now at:
/opt/traefik/acme/acme.json

# Backup runs hourly via sidecar
ls /backups/traefik/acme-*.json

# Force certificate renewal
docker exec -it <container-id> traefik \
  --certificatesresolvers.letsencrypt.acme.caserver=https://acme-v02.api.letsencrypt.org/directory
```

## Troubleshooting

### Common Issues

#### Port Already in Use
```bash
# Check what's using port 80/443
netstat -tulpn | grep -E ':80|:443'

# Kill process if needed
kill -9 <pid>
```

#### Certificate Not Loading
```bash
# Check permissions
ls -la /opt/traefik/acme/acme.json
# Should be 600

# Check inside container
docker exec -it <container-id> ls -la /acme/
```

#### Nomad Job Won't Start
```bash
# Check allocation events
nomad alloc status <alloc-id>

# Check Docker
docker ps -a
docker logs <container-id>

# Check resources
nomad node status -verbose
```

#### Service Discovery Not Working
```bash
# Verify Nomad provider config
docker exec -it <container-id> cat /etc/traefik/traefik.yml

# Check Nomad connectivity
curl http://localhost:4646/v1/status/leader
```

## Monitoring Commands

### Health Checks
```bash
# Traefik health
curl -s http://localhost/ping

# Dashboard access
curl -u admin:<password> https://traefik.cloudya.net/api/overview

# Service routes
curl -s http://localhost:8080/api/http/routers | jq
```

### Performance Metrics
```bash
# Prometheus metrics
curl -s http://localhost:8082/metrics | grep -E 'traefik_service_requests_total|traefik_entrypoint_requests_total'

# Container resources
docker stats <container-id>

# Nomad metrics
nomad alloc status -stats <alloc-id>
```

## Migration Timeline

| Phase | Duration | Actions |
|-------|----------|---------|
| Preparation | 15 min | Backup, copy files, verify |
| Deployment | 10 min | Deploy to Nomad, verify parallel |
| Cutover | 2 min | Stop systemd, switch traffic |
| Verification | 10 min | Test all endpoints |
| Monitoring | 24 hours | Watch for issues |
| Cleanup | 5 min | Remove old configs |

## Success Criteria

- [ ] All endpoints respond with correct status
- [ ] SSL certificates are valid
- [ ] Dashboard is accessible
- [ ] Metrics are being collected
- [ ] Auto-recovery works (test by killing container)
- [ ] No errors in logs for 1 hour
- [ ] Service discovery functioning
- [ ] Backup sidecar creating hourly backups

## Team Communication

### Before Migration
```
Team: Starting Traefik migration to Nomad
Duration: ~30 minutes
Impact: Minimal (zero-downtime planned)
Rollback: Available (< 1 minute)
```

### After Migration
```
Team: Traefik migration complete
Status: Running on Nomad
Monitoring: 24 hours stability check
Changes: Update bookmarks to new dashboard
```

## Next Steps After Migration

1. **Update Documentation**
   - Remove systemd instructions
   - Add Nomad management guide
   - Update runbooks

2. **Configure Alerts**
   - Nomad allocation failures
   - Certificate expiry warnings
   - Health check failures

3. **Plan Improvements**
   - Vault integration for secrets
   - Multi-node deployment
   - Advanced middleware

## Emergency Contacts

- Infrastructure Team: [slack channel]
- Nomad Dashboard: https://nomad.cloudya.net
- Traefik Dashboard: https://traefik.cloudya.net
- Rollback Hotline: [phone/slack]

---

**Remember**: The migration includes automatic rollback on failure. If anything goes wrong, the system will revert to systemd automatically.