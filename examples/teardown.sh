#!/bin/bash
# =============================================================================
# EKS Log Alarms - Teardown Script
# =============================================================================
# Deletes the CloudFormation stack (alarms, SNS topic, KMS key, IAM roles).
# NOTE: This does NOT remove in-cluster test resources created by
# tests/trigger.sh - use tests/cleanup.sh for that.
#
# Usage:
#   ./teardown.sh <cluster-name> [region]
# =============================================================================

set -euo pipefail

CLUSTER_NAME="${1:?Error: Cluster name is required. Usage: ./teardown.sh <cluster-name> [region]}"
AWS_REGION="${2:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
STACK_NAME="eks-log-alarms-${CLUSTER_NAME}"

echo "============================================"
echo "  EKS Log Alarms Teardown"
echo "============================================"
echo "  Stack:  ${STACK_NAME}"
echo "  Region: ${AWS_REGION}"
echo "============================================"
echo ""

read -p "Are you sure you want to delete all log alarms for cluster '${CLUSTER_NAME}'? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo "→ Deleting stack '${STACK_NAME}'..."
aws cloudformation delete-stack \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}"

echo "→ Waiting for deletion to complete..."
aws cloudformation wait stack-delete-complete \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}"

echo ""
echo "  ✓ Stack deleted successfully."
