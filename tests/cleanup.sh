#!/bin/bash
# =============================================================================
# EKS Log Alarms - Test Cleanup
# =============================================================================
# Removes every resource created by tests/trigger.sh so the alarm conditions
# stop and alarms transition back to OK after their evaluation windows pass
# (typically 15-25 minutes with the default 2-of-3 evaluation).
# NOTE: This does NOT delete the alarms/CloudFormation stack itself - use
# examples/teardown.sh for that.
#
# Safe to run repeatedly - every step is idempotent and skips anything
# already removed.
#
# Usage:
#   ./tests/cleanup.sh [cluster-name]
# =============================================================================

set -uo pipefail

CLUSTER_NAME="${1:-eks-log-alarms-demo}"
TEST_NAMESPACE="eks-alarm-test"
AUTH_TEST_ROLE="eks-log-alarm-test-unauthorized"

echo "============================================"
echo "  EKS Log Alarms - Test Cleanup"
echo "============================================"
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Namespace: ${TEST_NAMESPACE}"
echo "============================================"
echo ""

# -------------------------------------------------------------------------
# 1. Cluster-scoped webhook configurations
#    (must go first - otherwise the namespace delete below triggers them)
# -------------------------------------------------------------------------
echo "  Removing test webhook configurations..."
kubectl delete validatingwebhookconfiguration test-failing-webhook \
    --ignore-not-found
kubectl delete validatingwebhookconfiguration test-slow-webhook \
    --ignore-not-found

# -------------------------------------------------------------------------
# 1b. APF throttling objects (left behind only if a trigger run was
#     interrupted - trigger.sh normally removes them itself)
# -------------------------------------------------------------------------
echo "  Removing test APF flow control objects..."
kubectl delete flowschema test-throttle-fs --ignore-not-found
kubectl delete prioritylevelconfiguration test-throttle-plc --ignore-not-found

# -------------------------------------------------------------------------
# 2. Uncordon any node left cordoned by an interrupted drain test
# -------------------------------------------------------------------------
echo "  Checking for cordoned nodes..."
CORDONED=$(kubectl get nodes \
    -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
if [[ -n "${CORDONED}" ]]; then
    while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        echo "    Uncordoning ${node}..."
        kubectl uncordon "${node}" || true
    done <<< "${CORDONED}"
else
    echo "    None found."
fi

# -------------------------------------------------------------------------
# 3. Test namespace (removes deployments, PDBs, configmaps, secrets, jobs)
# -------------------------------------------------------------------------
echo "  Deleting test namespace ${TEST_NAMESPACE} (removes all test workloads)..."
kubectl delete namespace "${TEST_NAMESPACE}" --ignore-not-found --wait=false

# -------------------------------------------------------------------------
# 4. Temporary IAM role from the auth-denied test
# -------------------------------------------------------------------------
echo "  Removing temporary IAM test role..."
if aws iam get-role --role-name "${AUTH_TEST_ROLE}" > /dev/null 2>&1; then
    # Detach any managed policies before deleting the role
    for policy_arn in $(aws iam list-attached-role-policies \
        --role-name "${AUTH_TEST_ROLE}" \
        --query 'AttachedPolicies[].PolicyArn' --output text); do
        aws iam detach-role-policy \
            --role-name "${AUTH_TEST_ROLE}" \
            --policy-arn "${policy_arn}" || true
    done
    aws iam delete-role --role-name "${AUTH_TEST_ROLE}" || true
    echo "    Deleted role ${AUTH_TEST_ROLE}."
else
    echo "    Role not found, nothing to remove."
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Cleanup complete!"
echo "============================================"
echo ""
echo "  Alarm conditions have been removed. With the default schedule"
echo "  (5-minute queries, 2-of-3 evaluation), alarms should return to OK"
echo "  within 15-25 minutes as breaching datapoints age out."
echo ""
echo "  Watch the transition:"
echo ""
echo "  aws cloudwatch describe-alarms \\"
echo "    --alarm-name-prefix \"${CLUSTER_NAME}-\" \\"
echo "    --alarm-types LogAlarm \\"
echo "    --query 'LogAlarms[].{Name:AlarmName,State:StateValue}' \\"
echo "    --output table"
echo ""
