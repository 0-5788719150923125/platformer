#!/bin/bash
# Create Kubernetes secrets for Archshare EKS deployments
# Fetches RDS credentials from SSM and creates K8s secrets in tenant namespace
set -e

# Validate required environment variables
required_vars=(
  "TENANT"
  "NAMESPACE"
  "KUBECTL_CONTEXT"
  "AWS_REGION"
  "RDS_SERVICES_ENDPOINT"
  "RDS_SERVICES_PASSWORD"
  "RDS_STORAGE_ENDPOINT"
  "RDS_STORAGE_PASSWORD"
  "REDIS_SERVICES"
  "REDIS_STORAGE"
  "MEMCACHED"
  "S3_BUCKET"
  "ECR_REGISTRY"
)

for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "ERROR: Required environment variable $var is not set"
    exit 1
  fi
done

echo "Creating Kubernetes secrets for tenant: ${TENANT}"
echo "Using kubectl context: ${KUBECTL_CONTEXT}"
echo "Using RDS endpoints and credentials from Terraform..."

# Get ECR login token
echo "Fetching ECR authentication token..."
ECR_PASSWORD=$(aws ecr get-login-password --region "${AWS_REGION}")

# Create or update namespace
echo "Creating namespace: ${TENANT}"
kubectl create namespace "${TENANT}" --context="${KUBECTL_CONTEXT}" --dry-run=client -o yaml | kubectl apply --context="${KUBECTL_CONTEXT}" -f -

# Create ECR credentials secret (for pulling Docker images)
echo "Creating ECR credentials secret..."
kubectl create secret docker-registry ecr-credentials \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="${ECR_PASSWORD}" \
  --namespace="${TENANT}" \
  --context="${KUBECTL_CONTEXT}" \
  --dry-run=client -o yaml | kubectl apply --context="${KUBECTL_CONTEXT}" -f -

# Create services secret (for services chart)
# PGBOUNCER_CONFIG format matches Archshare requirements
# Note: RDS master username is set to database name (see storage/rds.tf line 98)
echo "Creating services-secret..."
kubectl create secret generic services-secret \
  --from-literal=PGBOUNCER_CONFIG='[{"name":"v3s","host":"'"${RDS_SERVICES_ENDPOINT}"'","port":5432,"pgbouncerHost":"127.0.0.1","pgbouncerPort":6543,"user":"v3s","password":"'"${RDS_SERVICES_PASSWORD}"'","master":"true"}]' \
  --from-literal=REDIS_SERVER="${REDIS_SERVICES}" \
  --from-literal=MEMCACHED_SERVERS="${MEMCACHED}" \
  --namespace="${TENANT}" \
  --context="${KUBECTL_CONTEXT}" \
  --dry-run=client -o yaml | kubectl apply --context="${KUBECTL_CONTEXT}" -f -

# Create storage secret (for storage chart)
# Storage chart expects environment variables that Spring Boot will substitute into YAML
# Based on archshare-v3storage CI configuration (storagetestS3Postgres)
echo "Creating storage-secrets..."

# Generate node IDs if not already set (for POC, use static UUIDs)
NODE_ID="${NODE_ID:-a0b0df88-8eb8-11ee-b0b7-f71b6303d8e8}"
NODE_SERIAL="${NODE_SERIAL:-aa07c902-8eb8-11ee-8a31-b76cd31ccd4f}"

kubectl create secret generic storage-secrets \
  --from-literal=NODE_ID="${NODE_ID}" \
  --from-literal=NODE_SERIAL="${NODE_SERIAL}" \
  --from-literal=SERVICES_SID="dummy-sid-for-poc-${TENANT}" \
  --from-literal=STUDY_DATABASE_JDBC="jdbc:postgresql://${RDS_STORAGE_ENDPOINT}:5432/imagedb?user=imagedb&password=${RDS_STORAGE_PASSWORD}&assumeMinServerVersion=14.0" \
  --from-literal=S3_BUCKET="${S3_BUCKET}" \
  --namespace="${TENANT}" \
  --context="${KUBECTL_CONTEXT}" \
  --dry-run=client -o yaml | kubectl apply --context="${KUBECTL_CONTEXT}" -f -

# Create watchdog secret (for watchdog chart)
# Watchdog uses PostgreSQL connection string format
echo "Creating watchdogservices-secrets..."
kubectl create secret generic watchdogservices-secrets \
  --from-literal=WATCHDOG_DB_CONNECT="host=${RDS_SERVICES_ENDPOINT} port=5432 user=v3s dbname=v3s password=${RDS_SERVICES_PASSWORD} sslmode=require" \
  --from-literal=WATCHDOG_APP_SECRET="dummy-app-secret-for-poc" \
  --from-literal=WATCHDOG_KEY="dummy-key-for-poc" \
  --namespace="${TENANT}" \
  --context="${KUBECTL_CONTEXT}" \
  --dry-run=client -o yaml | kubectl apply --context="${KUBECTL_CONTEXT}" -f -

echo "Successfully created Kubernetes secrets for tenant: ${TENANT}"
echo "Namespace: ${TENANT}"
echo "Secrets created: ecr-credentials, services-secret, storage-secrets, watchdogservices-secrets"
