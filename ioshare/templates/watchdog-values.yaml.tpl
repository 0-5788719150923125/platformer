imagePullSecrets:
  - name: ecr-credentials
image:
  repository: watchdogservices-rl-9-run
  tag: "3.25.1"
secretName: watchdogservices-secrets
env:
  WATCHDOG_SERVICES_URL: "http://services.${tenant_namespace}.svc.cluster.local:8020"
  WATCHDOG_SITE_URL: "http://${tenant_namespace}.example.com"
