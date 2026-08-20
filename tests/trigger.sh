#!/bin/bash
# =============================================================================
# EKS Log Alarms - Alarm Trigger Tests
# =============================================================================
# Run AFTER the cluster and alarms are deployed. Each test intentionally
# creates the condition a specific alarm detects. Run one test or all.
#
# Usage:
#   ./tests/trigger.sh [cluster-name] [test-name]
#
# Available tests (one per alarm):
#   webhook-failures   - Webhook pointing to a dead service backend
#   webhook-latency    - Webhook pointing to an unroutable URL (slow timeout)
#   api-throttling     - Parallel flood of configmap create/delete requests
#   pdb-eviction       - PDB that blocks eviction, then a node drain attempt
#   auth-denied        - Unmapped IAM role making cluster API calls
#   noisy-client       - Burst of 600 LIST pod requests
#   startup-probe      - Pods with a startup probe that always fails
#   all                - Run every test above (default)
#
# Not triggerable:
#   apiserver-health-check-failed - The /healthz signal comes from inside the
#   managed EKS control plane and cannot be induced from the user side.
#
# Best effort:
#   webhook-latency - The EKS managed control plane fails open in milliseconds
#   when a webhook backend does not complete a TLS handshake, so tarpit-style
#   backends do NOT produce latency annotations. This alarm only fires for a
#   webhook that speaks valid TLS and responds slowly (a real misbehaving
#   webhook). The test below deploys the condition but may not trip the alarm
#   on EKS. The alarm query matches the documented audit annotation format
#   (apiserver.latency.k8s.io/[mutating|validating]-webhook).
#
# After triggering, wait 15-20 minutes for alarms to evaluate, then run
# ./tests/cleanup.sh to remove the alarm conditions so alarms return to OK.
#
# Prerequisites:
#   - EKS cluster deployed and kubectl configured
#   - Log alarms stack deployed
# =============================================================================

set -euo pipefail

CLUSTER_NAME="${1:-eks-log-alarms-demo}"
TEST="${2:-all}"
TEST_NAMESPACE="eks-alarm-test"
AUTH_TEST_ROLE="eks-log-alarm-test-unauthorized"

echo "============================================"
echo "  EKS Log Alarms - Trigger Tests"
echo "============================================"
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Test:      ${TEST}"
echo "  Namespace: ${TEST_NAMESPACE}"
echo "  This creates resources that intentionally"
echo "  trigger alarm conditions. Clean up with:"
echo "    ./tests/cleanup.sh ${CLUSTER_NAME}"
echo "============================================"
echo ""

# All namespaced test resources live in a dedicated namespace so cleanup
# is a single namespace delete.
ensure_namespace() {
    kubectl create namespace "${TEST_NAMESPACE}" 2>/dev/null || true
    kubectl label namespace "${TEST_NAMESPACE}" eks-alarm-test=true --overwrite
}

# -------------------------------------------------------------------------
# Test: Webhook Failures
# Alarm: ${CLUSTER_NAME}-webhook-failures
# A validating webhook backed by a service with no endpoints. Every matching
# request logs "failed calling webhook" in the kube-apiserver log.
# -------------------------------------------------------------------------
run_webhook_failures() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: Webhook Failures"
    echo "  Creates a webhook pointing to a dead service"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_namespace

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fake-webhook-svc
  namespace: ${TEST_NAMESPACE}
spec:
  type: ClusterIP
  ports:
    - port: 443
      targetPort: 8443
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: test-failing-webhook
  labels:
    eks-alarm-test: "true"
webhooks:
  - name: test.failing.webhook.example.com
    clientConfig:
      service:
        name: fake-webhook-svc
        namespace: ${TEST_NAMESPACE}
        path: /validate
      caBundle: LS0tLS1CRUdJTi0tLS0tCk1JSUNERENDQWZTZ0F3SUJBZ0lVRGh5b2ZGVU1hM1lMdTBaVy9KNk1wTWRFSVVBd0RRWUpLb1pJaHZjTkFRRUwKLS0tLS1FTkQtLS0tLQo=
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["configmaps"]
        scope: "Namespaced"
    failurePolicy: Ignore
    sideEffects: None
    admissionReviewVersions: ["v1"]
    timeoutSeconds: 3
    namespaceSelector:
      matchLabels:
        eks-alarm-test: "true"
EOF

    # Create configmaps to trigger webhook calls (each fails - no backend)
    for i in $(seq 1 10); do
        kubectl create configmap "test-webhook-trigger-${i}" \
            --from-literal=test=value -n "${TEST_NAMESPACE}" 2>/dev/null || true
    done

    echo "  Webhook failure test deployed"
    echo "    Expected alarm: ${CLUSTER_NAME}-webhook-failures"
    echo ""
}

# -------------------------------------------------------------------------
# Test: Webhook Latency
# Alarm: ${CLUSTER_NAME}-webhook-latency
# BEST EFFORT (see header). A validating webhook backed by a "tarpit" pod
# that accepts TCP connections but never completes the TLS handshake.
# Verified behavior on EKS: the managed control plane fails open in
# milliseconds instead of waiting for timeoutSeconds, so no latency
# annotation is recorded and the alarm may not fire. The alarm itself is
# valid for real slow webhooks (valid TLS, slow response), which cannot be
# simulated without provisioning a certificate-bearing webhook server.
# NOTE: this produces "failed calling webhook" entries, so the
# webhook-failures alarm may fire as a side effect.
# -------------------------------------------------------------------------
run_webhook_latency() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: Webhook Latency"
    echo "  Creates a webhook that hangs ~10s per call"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_namespace

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slow-webhook-backend
  namespace: ${TEST_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: slow-webhook-backend
  template:
    metadata:
      labels:
        app: slow-webhook-backend
    spec:
      containers:
        - name: tarpit
          # Pinned version for supply-chain reproducibility (PCSR requirement)
          image: alpine/socat:1.8.1.3
          # Accepts TCP connections and holds them open (~30s) without ever
          # speaking TLS, so the API server waits for the webhook until
          # timeoutSeconds expires. socat forks per connection; busybox nc
          # is NOT suitable here - it closes concurrent connections instantly.
          command: ["socat", "-T", "30", "TCP-LISTEN:8443,fork,reuseaddr", "SYSTEM:sleep 30"]
---
apiVersion: v1
kind: Service
metadata:
  name: slow-webhook-svc
  namespace: ${TEST_NAMESPACE}
spec:
  selector:
    app: slow-webhook-backend
  ports:
    - port: 443
      targetPort: 8443
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: test-slow-webhook
  labels:
    eks-alarm-test: "true"
webhooks:
  - name: test.slow.webhook.example.com
    clientConfig:
      service:
        name: slow-webhook-svc
        namespace: ${TEST_NAMESPACE}
        path: /validate
      caBundle: LS0tLS1CRUdJTi0tLS0tCk1JSUNERENDQWZTZ0F3SUJBZ0lVRGh5b2ZGVU1hM1lMdTBaVy9KNk1wTWRFSVVBd0RRWUpLb1pJaHZjTkFRRUwKLS0tLS1FTkQtLS0tLQo=
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["secrets"]
        scope: "Namespaced"
    failurePolicy: Ignore
    sideEffects: None
    admissionReviewVersions: ["v1"]
    timeoutSeconds: 10
    namespaceSelector:
      matchLabels:
        eks-alarm-test: "true"
EOF

    echo "  Waiting for tarpit backend to be ready..."
    kubectl wait --for=condition=available deployment/slow-webhook-backend \
        -n "${TEST_NAMESPACE}" --timeout=60s 2>/dev/null || true

    echo "  Generating 6 slow admission calls (each hangs ~10s, run in parallel)..."
    for i in $(seq 1 6); do
        kubectl create secret generic "test-slow-webhook-${i}" \
            --from-literal=test=value -n "${TEST_NAMESPACE}" 2>/dev/null &
    done
    wait

    echo "  Webhook latency test deployed"
    echo "    Expected alarm: ${CLUSTER_NAME}-webhook-latency"
    echo ""
}

# -------------------------------------------------------------------------
# Test: API Throttling (429s)
# Alarm: ${CLUSTER_NAME}-api-throttling-429
# Default API Priority and Fairness limits are generous enough that a
# kubectl-speed flood rarely produces 429s. Instead, this test creates a
# narrowly-scoped FlowSchema (matching ONLY configmap writes by the current
# user in the test namespace) bound to a PriorityLevelConfiguration with
# minimal concurrency and queuing disabled (type: Reject). Modest parallel
# load against that scope then produces genuine 429 responses in the audit
# log without affecting any other traffic in the cluster.
# -------------------------------------------------------------------------
run_api_throttling() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: API Throttling (429s)"
    echo "  Scoped APF limit + parallel configmap load"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_namespace

    # Identify the current authenticated user so the FlowSchema matches
    # only this test's traffic.
    K8S_USER=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo "")
    if [[ -z "${K8S_USER}" ]]; then
        echo "  WARNING: could not determine current user (kubectl auth whoami)."
        echo "  Skipping api-throttling test."
        return
    fi
    echo "  Scoping throttle to user: ${K8S_USER}"

    kubectl apply -f - <<EOF
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: test-throttle-plc
  labels:
    eks-alarm-test: "true"
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 1
    lendablePercent: 0
    limitResponse:
      type: Reject
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: test-throttle-fs
  labels:
    eks-alarm-test: "true"
spec:
  priorityLevelConfiguration:
    name: test-throttle-plc
  matchingPrecedence: 500
  distinguisherMethod:
    type: ByUser
  rules:
    - subjects:
        - kind: User
          user:
            name: "${K8S_USER}"
      resourceRules:
        - verbs: ["create", "delete"]
          apiGroups: [""]
          resources: ["configmaps"]
          namespaces: ["${TEST_NAMESPACE}"]
EOF

    echo "  Waiting for APF config to propagate..."
    sleep 10

    echo "  Generating parallel configmap load against the throttled scope..."
    for stream in $(seq 1 10); do
        (
            for i in $(seq 1 30); do
                kubectl create configmap "throttle-test-${stream}-${i}" \
                    --from-literal=data="payload-${i}" \
                    -n "${TEST_NAMESPACE}" 2>/dev/null || true
                kubectl delete configmap "throttle-test-${stream}-${i}" \
                    -n "${TEST_NAMESPACE}" 2>/dev/null || true
            done
        ) &
    done
    wait

    # Remove the APF objects immediately - the 429s are already in the
    # audit log, and leaving a throttle in place would slow later tests.
    kubectl delete flowschema test-throttle-fs --ignore-not-found
    kubectl delete prioritylevelconfiguration test-throttle-plc --ignore-not-found

    echo "  API throttling test completed"
    echo "    Expected alarm: ${CLUSTER_NAME}-api-throttling-429"
    echo ""
}

# -------------------------------------------------------------------------
# Test: PDB Eviction Blocked
# Alarm: ${CLUSTER_NAME}-pdb-eviction-blocked
# Deploys 2 replicas with a PDB requiring minAvailable=2, then attempts a
# node drain. Every eviction attempt is denied and logged in the audit log.
# The drain is aborted and the node uncordoned before the test exits.
# -------------------------------------------------------------------------
run_pdb_eviction() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: PDB Eviction Blocked"
    echo "  2 replicas + PDB minAvailable=2, then drain"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_namespace

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pdb-block-test
  namespace: ${TEST_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pdb-block-test
  template:
    metadata:
      labels:
        app: pdb-block-test
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-block-test
  namespace: ${TEST_NAMESPACE}
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pdb-block-test
EOF

    echo "  Waiting for pods to be ready..."
    kubectl wait --for=condition=available deployment/pdb-block-test \
        -n "${TEST_NAMESPACE}" --timeout=120s 2>/dev/null || true
    sleep 5

    NODE=$(kubectl get pods -n "${TEST_NAMESPACE}" -l app=pdb-block-test \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")

    if [[ -z "${NODE}" ]]; then
        echo "  WARNING: No test pod scheduled. Skipping drain attempt."
        return
    fi

    echo "  Attempting to drain node: ${NODE}"
    echo "  (This SHOULD fail - PDB requires 2 available replicas)"
    echo ""

    # The drain retries eviction repeatedly, generating multiple denied
    # eviction entries in the audit log before kubectl's own --timeout
    # bounds the run. (No external timeout wrapper - GNU timeout is not
    # available on macOS by default.)
    kubectl drain "${NODE}" \
        --delete-emptydir-data \
        --ignore-daemonsets \
        --timeout=90s 2>&1 || echo "  (Drain failed as expected - PDB blocked eviction)"

    # Uncordon immediately so the node returns to service
    kubectl uncordon "${NODE}" 2>/dev/null || true

    echo ""
    echo "  PDB eviction test completed"
    echo "    Expected alarm: ${CLUSTER_NAME}-pdb-eviction-blocked"
    echo ""
}

# -------------------------------------------------------------------------
# Test: Auth Denied (Sustained)
# Alarm: ${CLUSTER_NAME}-auth-denied-sustained
# The alarm watches the AUTHENTICATOR log stream, so the denial must come
# from an IAM identity that is not mapped to the cluster. In-cluster RBAC
# denials (403s) do NOT appear in the authenticator log and will not fire
# this alarm. This test creates a temporary unmapped IAM role, assumes it,
# and makes repeated cluster API calls with it.
# -------------------------------------------------------------------------
run_auth_denied() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: Auth Denied (Sustained)"
    echo "  Uses an unmapped IAM identity to hit the cluster API"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Creates a temporary IAM role (${AUTH_TEST_ROLE})"
    echo "  that is NOT mapped to the cluster, then calls the API with it."
    echo "  The role is removed by ./tests/cleanup.sh."
    echo ""

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    aws iam create-role \
        --role-name "${AUTH_TEST_ROLE}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"AWS": "arn:aws:iam::'${ACCOUNT_ID}':root"},
                "Action": "sts:AssumeRole"
            }]
        }' 2>/dev/null || echo "  (Role may already exist)"

    echo "  Waiting for role to propagate..."
    sleep 10

    echo "  Attempting unauthorized API calls..."
    CREDS=$(aws sts assume-role \
        --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${AUTH_TEST_ROLE}" \
        --role-session-name "alarm-test" \
        --query 'Credentials' --output json 2>/dev/null || echo "")

    if [[ -n "${CREDS}" ]]; then
        # Run in a subshell so the temporary credentials never leak into
        # the caller's environment.
        (
            AWS_ACCESS_KEY_ID=$(echo "${CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")
            AWS_SECRET_ACCESS_KEY=$(echo "${CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")
            AWS_SESSION_TOKEN=$(echo "${CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin)['SessionToken'])")
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

            # Each call is rejected by the EKS authenticator and logged
            for i in $(seq 1 20); do
                kubectl get pods -A 2>&1 || true
                sleep 1
            done
        )
    else
        echo "  WARNING: Could not assume test role."
        echo "  Manual alternative - from a second terminal with an AWS profile"
        echo "  that is NOT mapped to the cluster:"
        echo ""
        echo "    aws eks update-kubeconfig --name ${CLUSTER_NAME} --alias unauthorized-test"
        echo "    for i in \$(seq 1 30); do"
        echo "      kubectl --context unauthorized-test get pods -A 2>&1 || true"
        echo "      sleep 2"
        echo "    done"
    fi

    echo "  Auth denied test completed"
    echo "    Expected alarm: ${CLUSTER_NAME}-auth-denied-sustained"
    echo ""
}

# -------------------------------------------------------------------------
# Test: Noisy Client (List Storms)
# Alarm: ${CLUSTER_NAME}-noisy-client-list-storms
# Sends 600 LIST pod requests in a short burst (threshold: 500 per 5 min).
# No resources are created; the noise stops when the burst completes.
# -------------------------------------------------------------------------
run_noisy_client() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: Noisy Client (List Storms)"
    echo "  Generates 600 LIST pod requests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    for i in $(seq 1 600); do
        kubectl get pods -A > /dev/null 2>&1 &
        if (( i % 50 == 0 )); then
            echo "  Sent ${i}/600 requests..."
            wait  # Avoid too many background processes
        fi
    done
    wait

    echo "  Noisy client test completed"
    echo "    Expected alarm: ${CLUSTER_NAME}-noisy-client-list-storms"
    echo ""
}

# -------------------------------------------------------------------------
# Test: Startup Probe Failures
# Alarm: ${CLUSTER_NAME}-startup-probe-failures
# Pods with a startup probe on a closed port fail continuously, generating
# "Startup probe failed" events until cleaned up.
# -------------------------------------------------------------------------
run_startup_probe() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test: Startup Probe Failures"
    echo "  Deploys pods with a probe on a closed port"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    ensure_namespace

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-startup-probe-fail
  namespace: ${TEST_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: probe-fail-test
  template:
    metadata:
      labels:
        app: probe-fail-test
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          startupProbe:
            httpGet:
              path: /nonexistent
              port: 9999
            failureThreshold: 30
            periodSeconds: 2
EOF

    echo "  Startup probe failure test deployed"
    echo "    Expected alarm: ${CLUSTER_NAME}-startup-probe-failures"
    echo ""
}

# -------------------------------------------------------------------------
# Run selected tests
# -------------------------------------------------------------------------
case "${TEST}" in
    webhook-failures)  run_webhook_failures ;;
    webhook-latency)   run_webhook_latency ;;
    api-throttling)    run_api_throttling ;;
    pdb-eviction)      run_pdb_eviction ;;
    auth-denied)       run_auth_denied ;;
    noisy-client)      run_noisy_client ;;
    startup-probe)     run_startup_probe ;;
    all)
        run_webhook_failures
        run_webhook_latency
        run_api_throttling
        run_pdb_eviction
        run_auth_denied
        run_noisy_client
        run_startup_probe
        ;;
    *)
        echo "Unknown test: ${TEST}"
        echo "Available: webhook-failures, webhook-latency, api-throttling,"
        echo "           pdb-eviction, auth-denied, noisy-client, startup-probe, all"
        exit 1
        ;;
esac

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Tests triggered!"
echo "============================================"
echo ""
echo "  Note: the apiserver-health-check-failed alarm cannot be triggered"
echo "  from the user side - its signal originates inside the managed EKS"
echo "  control plane."
echo ""
echo "  Wait 15-20 minutes for alarm evaluation, then check alarm states:"
echo ""
echo "  aws cloudwatch describe-alarms \\"
echo "    --alarm-name-prefix \"${CLUSTER_NAME}-\" \\"
echo "    --alarm-types LogAlarm \\"
echo "    --query 'LogAlarms[].{Name:AlarmName,State:StateValue}' \\"
echo "    --output table"
echo ""
echo "  When done, remove the alarm conditions so alarms return to OK:"
echo ""
echo "    ./tests/cleanup.sh ${CLUSTER_NAME}"
echo ""
