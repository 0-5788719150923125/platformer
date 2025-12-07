#!/bin/bash
# Wrapper script for aws eks get-token that gracefully handles missing clusters
# Used by Helm provider to avoid failures when no EKS cluster exists

set -euo pipefail

CLUSTER_NAME="${1:-none}"
REGION="${2:-us-east-2}"

# If cluster name is "none" or empty, return a dummy token response
# This prevents the provider from failing when no EKS cluster exists
if [ "$CLUSTER_NAME" = "none" ] || [ -z "$CLUSTER_NAME" ]; then
  # Return a valid-looking ExecCredential structure with a dummy token
  # The token won't be used because there's no cluster to connect to
  cat <<EOF
{
  "apiVersion": "client.authentication.k8s.io/v1beta1",
  "kind": "ExecCredential",
  "status": {
    "token": "dummy-token-no-cluster-exists"
  }
}
EOF
  exit 0
fi

# Cluster exists - call AWS CLI to get real token
exec aws eks get-token --cluster-name "$CLUSTER_NAME" --region "$REGION"
