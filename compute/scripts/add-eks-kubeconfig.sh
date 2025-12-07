#!/bin/bash
# Add or update EKS cluster entry in kubeconfig
# Usage: add-eks-kubeconfig.sh <cluster_name> <region> <account_id> <context_alias> <profile>
#
# Arguments:
#   cluster_name   - Name of the EKS cluster
#   region         - AWS region (e.g., us-east-2)
#   account_id     - AWS account ID
#   context_alias  - Alias name for the kubectl context
#   profile        - AWS CLI profile to use for authentication
#
# Example:
#   ./add-eks-kubeconfig.sh eks-test-aveneit us-east-2 555555555555 eks-test example-platform-dev

set -e

if [ "$#" -ne 5 ]; then
  echo "Error: Missing required arguments" >&2
  echo "Usage: $0 <cluster_name> <region> <account_id> <context_alias> <profile>" >&2
  exit 1
fi

CLUSTER_NAME="$1"
REGION="$2"
ACCOUNT_ID="$3"
CONTEXT_ALIAS="$4"
PROFILE="$5"

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
LOCKFILE="${KUBECONFIG_PATH}.terraform.lock"

echo "Adding kubeconfig entry for cluster: $CLUSTER_NAME"

# Acquire file lock to prevent concurrent kubeconfig writes
exec 200>"$LOCKFILE"
flock 200

# Add/update kubeconfig entry using AWS CLI
aws eks update-kubeconfig \
  --profile "$PROFILE" \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --alias "$CONTEXT_ALIAS"

# Update credentials to use the correct profile for authentication
kubectl config set-credentials "arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}" \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=aws \
  --exec-arg=eks \
  --exec-arg=get-token \
  --exec-arg=--cluster-name \
  --exec-arg="$CLUSTER_NAME" \
  --exec-arg=--region \
  --exec-arg="$REGION" \
  --exec-arg=--profile \
  --exec-arg="$PROFILE"

echo "Kubeconfig entry added successfully"
