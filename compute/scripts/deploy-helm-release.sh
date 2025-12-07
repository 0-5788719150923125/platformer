#!/bin/bash
# Deploy Helm release to EKS cluster using helm CLI
# Called by null_resource.helm_release in compute/helm.tf
#
# This script provides CLI-based Helm deployment to support multiple EKS clusters
# Terraform's Helm provider is a singleton and cannot handle dynamic cluster counts

set -euo pipefail

# Required environment variables
: "${CLUSTER_NAME:?CLUSTER_NAME environment variable must be set}"
: "${KUBECONFIG_CONTEXT:?KUBECONFIG_CONTEXT environment variable must be set}"
: "${RELEASE_NAME:?RELEASE_NAME environment variable must be set}"
: "${CHART:?CHART environment variable must be set}"
: "${REPOSITORY:?REPOSITORY environment variable must be set}"
: "${NAMESPACE:?NAMESPACE environment variable must be set}"

# Optional environment variables with defaults
VERSION="${VERSION:-}"
WAIT="${WAIT:-true}"
TIMEOUT="${TIMEOUT:-300}"
VALUES="${VALUES:-}"

echo "================================================================"
echo "Deploying Helm Release"
echo "================================================================"
echo "Cluster:      ${CLUSTER_NAME}"
echo "Context:      ${KUBECONFIG_CONTEXT}"
echo "Release:      ${RELEASE_NAME}"
echo "Chart:        ${CHART}"
echo "Repository:   ${REPOSITORY}"
echo "Version:      ${VERSION:-latest}"
echo "Namespace:    ${NAMESPACE}"
echo "================================================================"

# Authenticate to ECR if using OCI registry
if [[ "${REPOSITORY}" =~ ^oci://.*\.dkr\.ecr\..*\.amazonaws\.com ]]; then
  echo "Authenticating to ECR..."
  REGISTRY=$(echo "${REPOSITORY}" | sed 's|oci://||' | sed 's|/.*||')
  AWS_REGION=$(echo "${REGISTRY}" | sed -E 's/.*\.ecr\.([^.]+)\..*/\1/')

  # Use AWS_PROFILE if set, otherwise use default credentials
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    echo "Using AWS profile: ${AWS_PROFILE}"
    AWS_PROFILE="${AWS_PROFILE}" aws ecr get-login-password --region "${AWS_REGION}" | \
      helm registry login "${REGISTRY}" --username AWS --password-stdin
  else
    aws ecr get-login-password --region "${AWS_REGION}" | \
      helm registry login "${REGISTRY}" --username AWS --password-stdin
  fi
  echo "✓ ECR authentication successful"
fi

# Check if release exists and is in a broken state
RELEASE_STATUS=$(helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" --kube-context "${KUBECONFIG_CONTEXT}" -o json 2>/dev/null | jq -r '.info.status // ""' || echo "")

if [[ "${RELEASE_STATUS}" == "pending-upgrade" || "${RELEASE_STATUS}" == "pending-install" || "${RELEASE_STATUS}" == "pending-rollback" || "${RELEASE_STATUS}" == "failed" ]]; then
  echo "⚠ Release ${RELEASE_NAME} is in ${RELEASE_STATUS} state"
  echo "  Deleting release to allow clean reinstall..."
  # Delete the release entirely to break out of broken state
  # Using --no-hooks to skip pre-delete hooks that might also be stuck
  helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}" --kube-context "${KUBECONFIG_CONTEXT}" --wait --timeout=60s || true
  echo "✓ Release deleted, proceeding with fresh install"
  # Give Kubernetes a moment to clean up resources
  sleep 5
fi

# Build helm command
# OCI registries require full chart reference (oci://registry/chart), not --repo flag
if [[ "${REPOSITORY}" =~ ^oci:// ]]; then
  # OCI registry: combine repository and chart into single reference
  CHART_REF="${REPOSITORY}/${CHART}"
  CMD=(helm upgrade --install "${RELEASE_NAME}" "${CHART_REF}")
else
  # Traditional repository: use --repo flag
  CMD=(helm upgrade --install "${RELEASE_NAME}" "${CHART}")
  CMD+=(--repo "${REPOSITORY}")
fi

CMD+=(--namespace "${NAMESPACE}")
CMD+=(--kube-context "${KUBECONFIG_CONTEXT}")

# Add optional flags
[[ -n "${VERSION}" ]] && CMD+=(--version "${VERSION}")
[[ "${WAIT}" == "true" ]] && CMD+=(--wait --timeout "${TIMEOUT}s")
# Cleanup on failure and disable server-side apply to allow resource recreation
CMD+=(--cleanup-on-fail)

# Handle inline values (write to temp file)
if [[ -n "${VALUES}" ]]; then
  VALUES_FILE=$(mktemp)
  echo "${VALUES}" > "${VALUES_FILE}"
  CMD+=(--values "${VALUES_FILE}")
  trap "rm -f ${VALUES_FILE}" EXIT
fi

# Execute helm command
echo "Executing: ${CMD[*]}"
echo "----------------------------------------------------------------"
"${CMD[@]}"

echo "================================================================"
echo "✓ Successfully deployed ${RELEASE_NAME}"
echo "================================================================"
