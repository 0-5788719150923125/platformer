servicesSecretName: services-secret
imagePullSecrets:
  - name: ecr-credentials
stunnel:
  enabled: false
pgbouncer:
  enabled: true
sidecarContainers:
  - name: redis-proxy
    image: alpine/socat:latest
    command: ["socat"]
    args:
      - "TCP4-LISTEN:6379,fork,reuseaddr"
      - "TCP4:${redis_services_endpoint}:6379"
  - name: memcached-proxy
    image: alpine/socat:latest
    command: ["socat"]
    args:
      - "TCP4-LISTEN:11211,fork,reuseaddr"
      - "TCP4:${memcached_endpoint}:11211"
