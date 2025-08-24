job "traefik" {
  datacenters = ["dc1"]
  type        = "service"
  priority    = 100

  update {
    max_parallel      = 1
    health_check      = "checks"
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    auto_promote      = true
    canary            = 0
  }

  group "traefik" {
    count = 1

    # CRITICAL: Host volumes for persistent certificate storage
    volume "traefik-certs" {
      type      = "host"
      read_only = false
      source    = "traefik-certs"
    }

    volume "traefik-config" {
      type      = "host"
      read_only = false
      source    = "traefik-config"
    }

    network {
      mode = "host"
      
      port "web" {
        static = 80
      }
      
      port "websecure" {
        static = 443
      }
      
      port "metrics" {
        static = 8082
      }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "30s"
      mode     = "delay"
    }

    task "traefik" {
      driver = "docker"
      
      volume_mount {
        volume      = "traefik-certs"
        destination = "/letsencrypt"
        read_only   = false
      }

      volume_mount {
        volume      = "traefik-config"
        destination = "/config"
        read_only   = false
      }

      config {
        image = "traefik:v3.2.3"
        network_mode = "host"
        
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ]
      }

      env {
        TRAEFIK_LOG_LEVEL = "INFO"
        TRAEFIK_API_DASHBOARD = "true"
        TRAEFIK_PING = "true"
        
        # HTTP entrypoint with redirect to HTTPS
        TRAEFIK_ENTRYPOINTS_WEB_ADDRESS = ":80"
        TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO = "websecure"
        TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_SCHEME = "https"
        TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_PERMANENT = "true"
        
        # HTTPS entrypoint
        TRAEFIK_ENTRYPOINTS_WEBSECURE_ADDRESS = ":443"
        TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS = "true"
        TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_CERTRESOLVER = "letsencrypt"
        
        # Metrics
        TRAEFIK_ENTRYPOINTS_METRICS_ADDRESS = ":8082"
        
        # Let's Encrypt Configuration
        TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL = "admin@cloudya.net"
        TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_STORAGE = "/letsencrypt/acme.json"
        TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_KEYTYPE = "EC256"
        TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_HTTPCHALLENGE_ENTRYPOINT = "web"
        TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_CASERVER = "https://acme-v02.api.letsencrypt.org/directory"
        
        # File provider for dynamic config
        TRAEFIK_PROVIDERS_FILE_DIRECTORY = "/config/dynamic"
        TRAEFIK_PROVIDERS_FILE_WATCH = "true"
        
        # Metrics
        TRAEFIK_METRICS_PROMETHEUS = "true"
        TRAEFIK_METRICS_PROMETHEUS_ENTRYPOINT = "metrics"
        
        # Access logs
        TRAEFIK_ACCESSLOG = "true"
        TRAEFIK_ACCESSLOG_FORMAT = "json"
      }

      template {
        destination = "local/dynamic/routes.yml"
        perms       = "644"
        change_mode = "signal"
        change_signal = "SIGHUP"
        data        = <<EOF
http:
  routers:
    dashboard:
      rule: "Host(`traefik.cloudya.net`)"
      service: api@internal
      middlewares:
        - auth-dashboard
        - security-headers
      tls:
        certResolver: letsencrypt
    
    vault:
      rule: "Host(`vault.cloudya.net`)"
      service: vault-service
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt
    
    nomad:
      rule: "Host(`nomad.cloudya.net`)"
      service: nomad-service
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt
    
    metrics:
      rule: "Host(`metrics.cloudya.net`)"
      service: prometheus-service
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt
    
    grafana:
      rule: "Host(`grafana.cloudya.net`)"
      service: grafana-service
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt
    
    api:
      rule: "Host(`api.cloudya.net`)"
      service: backend-service
      middlewares:
        - security-headers
        - cors
      tls:
        certResolver: letsencrypt
    
    app:
      rule: "Host(`app.cloudya.net`) || Host(`cloudya.net`)"
      service: frontend-service
      middlewares:
        - security-headers
      tls:
        certResolver: letsencrypt

  services:
    vault-service:
      loadBalancer:
        servers:
          - url: "http://localhost:8200"
    
    nomad-service:
      loadBalancer:
        servers:
          - url: "http://localhost:4646"
    
    prometheus-service:
      loadBalancer:
        servers:
          - url: "http://localhost:9090"
    
    grafana-service:
      loadBalancer:
        servers:
          - url: "http://localhost:3000"
    
    backend-service:
      loadBalancer:
        servers:
          - url: "http://localhost:8000"
    
    frontend-service:
      loadBalancer:
        servers:
          - url: "http://localhost:3001"

  middlewares:
    auth-dashboard:
      basicAuth:
        users:
          - "admin:$2y$10$9L.K4cPdl8rwLgiYBNO9H.7L9X9RNzycQP7gFPNsuAcLqsXoLyoO2"
    
    security-headers:
      headers:
        frameDeny: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 63072000
    
    cors:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
          - POST
          - DELETE
        accessControlAllowHeaders:
          - "*"
        accessControlAllowOriginList:
          - "https://cloudya.net"
          - "https://app.cloudya.net"
        accessControlMaxAge: 86400

tls:
  stores:
    default:
      defaultGeneratedCert:
        resolver: letsencrypt
        domain:
          main: ""
EOF
      }

      template {
        destination = "local/copy-config.sh"
        perms       = "755"
        data        = <<EOF
#!/bin/sh
cp -f local/dynamic/routes.yml /config/dynamic/routes.yml 2>/dev/null || true
EOF
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name = "traefik"
        port = "web"
        tags = ["traefik", "lb", "web"]
        
        check {
          type     = "http"
          port     = "web"
          path     = "/ping"
          interval = "10s"
          timeout  = "2s"
          
          check_restart {
            limit = 3
            grace = "90s"
          }
        }
      }

      service {
        name = "traefik-secure"
        port = "websecure"
        tags = ["traefik", "lb", "websecure"]
      }

      service {
        name = "traefik-metrics"
        port = "metrics"
        tags = ["traefik", "metrics", "prometheus"]
        
        check {
          type     = "http"
          port     = "metrics"
          path     = "/metrics"
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    task "init-storage" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "raw_exec"
      
      config {
        command = "/bin/bash"
        args    = ["-c", <<EOF
#!/bin/bash
set -e

echo "Initializing Traefik persistent storage..."

# Create directories on host
mkdir -p /opt/nomad/volumes/traefik-certs
mkdir -p /opt/nomad/volumes/traefik-config/dynamic

# Initialize ACME storage if it doesn't exist
if [ ! -f /opt/nomad/volumes/traefik-certs/acme.json ]; then
  echo '{}' > /opt/nomad/volumes/traefik-certs/acme.json
  chmod 600 /opt/nomad/volumes/traefik-certs/acme.json
  echo "Created new ACME storage file"
else
  echo "ACME storage already exists"
  chmod 600 /opt/nomad/volumes/traefik-certs/acme.json
fi

# Set permissions
chmod 700 /opt/nomad/volumes/traefik-certs
chmod 755 /opt/nomad/volumes/traefik-config

echo "Storage initialization complete"
ls -la /opt/nomad/volumes/traefik-certs/
EOF
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}