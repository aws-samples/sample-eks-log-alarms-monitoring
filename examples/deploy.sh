#!/bin/bash
# =============================================================================
# EKS Log Alarms - Quick Deploy Script
# =============================================================================
# Usage:
#   ./deploy.sh <cluster-name> [email] [region]
#
# Examples:
#   ./deploy.sh my-production-cluster ops@company.com us-west-2
#   ./deploy.sh dev-cluster  # Uses defaults (no email, current region)
# =============================================================================

set -euo pipefail

CLUSTER_NAME="${1:?Error: Cluster name is required. Usage: ./deploy.sh <cluster-name> [email] [region]}"
NOTIFICATION_EMAIL="${2:-}"
AWS_REGION="${3:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}"
STACK_NAME="eks-log-alarms-${CLUSTER_NAME}"
TEMPLATE_FILE="$(dirname "$0")/../template.yaml"

echo "============================================"
echo "  EKS Log Alarms Deployment"
echo "============================================"
echo "  Cluster:  ${CLUSTER_NAME}"
echo "  Region:   ${AWS_REGION}"
echo "  Stack:    ${STACK_NAME}"
echo "  Email:    ${NOTIFICATION_EMAIL:-<none>}"
echo "============================================"
echo ""

# Validate cluster exists
echo "→ Validating EKS cluster exists..."
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: EKS cluster '${CLUSTER_NAME}' not found in region '${AWS_REGION}'"
    exit 1
fi
echo "  ✓ Cluster found"

# Check control plane logging is enabled
echo "→ Checking control plane logging..."
LOGGING=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.logging.clusterLogging[?enabled==`true`].types[]' --output text 2>/dev/null)

if [[ -z "${LOGGING}" ]]; then
    echo "  ⚠ WARNING: No control plane logging enabled. Some alarms may not function."
    echo "    Enable logging: https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html"
    echo ""
    read -p "  Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "  ✓ Enabled log types: ${LOGGING}"
fi

# Validate template
echo "→ Validating CloudFormation template..."
aws cloudformation validate-template \
    --template-body "file://${TEMPLATE_FILE}" \
    --region "${AWS_REGION}" > /dev/null
echo "  ✓ Template valid"

# Build parameter overrides
PARAMS="ClusterName=${CLUSTER_NAME}"
PARAMS="${PARAMS} CreateSNSTopic=true"

if [[ -n "${NOTIFICATION_EMAIL}" ]]; then
    PARAMS="${PARAMS} NotificationEmail=${NOTIFICATION_EMAIL}"
fi

# Deploy
echo "→ Deploying stack '${STACK_NAME}'..."
echo ""

if [[ ! -f "${TEMPLATE_FILE}" ]]; then
    echo "ERROR: Template file not found: ${TEMPLATE_FILE}"
    exit 1
fi

aws cloudformation deploy \
    --template-file "${TEMPLATE_FILE}" \
    --stack-name "${STACK_NAME}" \
    --parameter-overrides \
        "ClusterName=${CLUSTER_NAME}" \
        "CreateSNSTopic=true" \
        "NotificationEmail=${NOTIFICATION_EMAIL}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${AWS_REGION}" \
    --tags \
        "Project=eks-log-alarms" \
        "EKSCluster=${CLUSTER_NAME}" \
        "ManagedBy=cloudformation"

echo ""
echo "============================================"
echo "  ✓ Deployment complete!"
echo "============================================"
echo ""

# Print outputs
echo "Stack outputs:"
aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${AWS_REGION}" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table
