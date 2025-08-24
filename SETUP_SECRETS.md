# GitHub Secrets Configuration for Traefik Deployment

To deploy Traefik via Nomad API, you need to configure the following GitHub secrets:

## Required Secrets

### 1. NOMAD_ADDR
The URL to your Nomad server API endpoint.

**Value:** `https://nomad.cloudya.net`

### 2. NOMAD_TOKEN
The authentication token for Nomad API access.

**How to get the token:**
```bash
# On the Nomad server, create a management token:
nomad acl token create -type="management" -name="github-actions" -global
```

Or if you have an existing token, retrieve it from:
- Vault at path: `kv/data/nomad/tokens`
- Or from your Nomad ACL configuration

### 3. SERVER_IP (Optional - for verification)
The IP address of your server for health checks.

**Value:** Your server's public IP address

### 4. ACME_EMAIL (Optional)
Email for Let's Encrypt certificate registration.

**Value:** `admin@cloudya.net` or your admin email

## How to Set These Secrets

1. Go to the repository: https://github.com/rendermani/traefik
2. Navigate to Settings → Secrets and variables → Actions
3. Click "New repository secret"
4. Add each secret with the name and value specified above

## Verification

After setting the secrets, you can verify the deployment works by:

1. Going to Actions tab
2. Selecting "Deploy Traefik" workflow
3. Click "Run workflow"
4. Choose:
   - Action: `deploy-nomad`
   - Environment: `staging` or `production`
5. Click "Run workflow"

The workflow will:
- Deploy Traefik via Nomad API (no SSH required)
- Test SSL certificates with OpenSSL
- Verify Let's Encrypt certificates are working
- Check that no default certificates exist

## Important Notes

- The NOMAD_TOKEN must have sufficient permissions to submit jobs
- Ensure the Nomad API is accessible from GitHub Actions runners
- The token should be kept secure and rotated periodically
- Consider using Vault for token management in production