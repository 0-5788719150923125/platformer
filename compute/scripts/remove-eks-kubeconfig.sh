#!/bin/bash
# Remove EKS cluster entries from kubeconfig
# Usage: remove-eks-kubeconfig.sh <cluster_arn> <cluster_name> <context_name>
#
# Arguments:
#   cluster_arn   - Full ARN of the EKS cluster (e.g., arn:aws:eks:us-east-2:555555555555:cluster/eks-test-aveneit)
#   cluster_name  - Name of the EKS cluster
#   context_name  - Name of the kubectl context to remove
#
# Example:
#   ./remove-eks-kubeconfig.sh "arn:aws:eks:us-east-2:555555555555:cluster/eks-test-aveneit" eks-test-aveneit eks-test

set -e

if [ "$#" -ne 3 ]; then
  echo "Error: Missing required arguments" >&2
  echo "Usage: $0 <cluster_arn> <cluster_name> <context_name>" >&2
  exit 1
fi

CLUSTER_ARN="$1"
CLUSTER_NAME="$2"
CONTEXT_NAME="$3"

# Extract region and account from ARN
REGION=$(echo "$CLUSTER_ARN" | cut -d: -f4)
ACCOUNT=$(echo "$CLUSTER_ARN" | cut -d: -f5)

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
LOCKFILE="${KUBECONFIG_PATH}.terraform.lock"

echo "Removing kubeconfig entries for cluster: $CLUSTER_NAME"

# Acquire file lock to prevent concurrent kubeconfig writes
exec 200>"$LOCKFILE"
flock 200

# Delete context
if kubectl config delete-context "$CONTEXT_NAME" 2>/dev/null; then
  echo "  Deleted context: $CONTEXT_NAME"
else
  echo "  - Context not found: $CONTEXT_NAME"
fi

# Delete cluster entry
CLUSTER_FULL_ARN="arn:aws:eks:$REGION:$ACCOUNT:cluster/$CLUSTER_NAME"
if kubectl config delete-cluster "$CLUSTER_FULL_ARN" 2>/dev/null; then
  echo "  Deleted cluster entry: $CLUSTER_FULL_ARN"
else
  echo "  - Cluster entry not found: $CLUSTER_FULL_ARN"
fi

# Delete user entry
USER_ARN="users.arn:aws:eks:$REGION:$ACCOUNT:cluster/$CLUSTER_NAME"
if kubectl config unset "$USER_ARN" 2>/dev/null; then
  echo "  Deleted user entry: $USER_ARN"
else
  echo "  - User entry not found: $USER_ARN"
fi

echo "Kubeconfig cleanup complete"
