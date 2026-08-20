# EKS Control Plane Log Alarm Patterns

Detailed reference for each alarm in this solution. Every alarm targets a signal that **only exists in EKS control plane logs** — no CloudWatch metric covers it, or the existing metric lacks the per-resource detail needed to act.

---

## 1. Webhook Failures

**What it detects:** Admission webhooks (validating or mutating) failing to respond to the API server.

**Why no metric covers this:** The `apiserver_admission_webhook_fail_open_count` metric exists but only counts *fail-open* outcomes. It misses fail-closed rejections entirely and provides no webhook name breakdown.

**Log source:** `kube-apiserver` (non-audit stream)

**Query:**
```
filter @logStream like /kube-apiserver/ and @logStream not like /kube-apiserver-audit/
| filter @message like /failed calling webhook/
| parse @message 'failed calling webhook "*"' as webhook_name
| stats count(*) as failureCount by bin(5m)
```

**Default threshold:** ≥ 5 failures in a 5-minute window

**Tuning guidance:**
- Raise to 10–20 for clusters with webhooks known to intermittently timeout (e.g., OPA Gatekeeper under load).
- Lower to 1 for production clusters where any webhook failure blocks deployments (fail-closed policy).

**Response runbook:**
1. Identify the failing webhook name from the alarm notification log lines.
2. Check the webhook backing service: `kubectl get svc -A | grep <webhook-svc>` — confirm pods are running.
3. Inspect webhook configuration for timeout/failurePolicy: `kubectl get validatingwebhookconfigurations` / `mutatingwebhookconfigurations`.
4. Check network policy or security group rules blocking API server → webhook pod traffic.
5. If non-critical, set `failurePolicy: Ignore` temporarily to unblock the API.

---

## 2. Webhook Latency

**What it detects:** Mutating or validating webhooks adding > 5 seconds of latency to API calls.

**Why no metric covers this:** `apiserver_request_duration_seconds` captures total request latency but does not break down how much each webhook contributed. The audit log annotations provide per-webhook timing.

**Log source:** `kube-apiserver-audit`

**Query:**
```
filter @logStream like /kube-apiserver-audit/
| filter ispresent(`annotations.apiserver.latency.k8s.io/mutating-webhook`) or ispresent(`annotations.apiserver.latency.k8s.io/validating-webhook`)
| parse `annotations.apiserver.latency.k8s.io/mutating-webhook` "*s" as mutating_secs
| parse `annotations.apiserver.latency.k8s.io/validating-webhook` "*s" as validating_secs
| filter (ispresent(mutating_secs) and mutating_secs > 5) or (ispresent(validating_secs) and validating_secs > 5)
| stats count(*) as slowCalls by bin(5m)
```

**Default threshold:** ≥ 3 slow calls in a 5-minute window

**Tuning guidance:**
- Raise if you have known-slow webhooks that are acceptable (e.g., policy engines analyzing large resources).
- Lower to 1 if SLO requires sub-second API latency.
- Adjust the `> 5` seconds filter in the query to match your latency tolerance.

**Testing note:** this alarm cannot be reliably triggered synthetically on EKS. The managed control plane fails open in milliseconds when a webhook backend does not complete a TLS handshake (unreachable addresses and TCP tarpits both fail fast), and latency annotations are only recorded for webhooks that speak valid TLS and respond slowly. The alarm fires for real misbehaving webhooks — e.g., an overloaded policy engine — not for connection-level failures (those surface via the Webhook Failures alarm instead).

**Response runbook:**
1. Parse the audit log entry to identify which webhook annotation shows high latency.
2. Check the backing pod resource usage: `kubectl top pods -n <webhook-ns>`.
3. Review webhook timeout configuration — consider reducing `timeoutSeconds` to fail fast.
4. Verify no network latency between API server and webhook (cross-AZ calls, DNS resolution).
5. Scale the webhook deployment if load-induced.

---

## 3. API Server Health Check Failed

**What it detects:** The kube-apiserver's internal `/healthz` endpoint reporting failed checks.

**Why no metric covers this:** There is no CloudWatch metric that exposes individual healthz sub-check results. EKS surfaces this only in the apiserver process logs.

**Log source:** `kube-apiserver` (non-audit stream)

**Query:**
```
filter @logStream like /kube-apiserver/ and @logStream not like /kube-apiserver-audit/
| filter @message like /healthz check failed/
| stats count(*) as healthCheckFailures by bin(5m)
```

**Default threshold:** ≥ 3 failures in a 5-minute window

**Tuning guidance:**
- This alarm is uncommon in healthy clusters. Any sustained occurrence is serious.
- Keep threshold low (1–3). Transient blips can occur during control plane upgrades.

**Response runbook:**
1. Check the log message for which sub-check failed (etcd, poststarthook, etc.).
2. Verify cluster API responsiveness: `kubectl get --raw='/healthz?verbose'`.
3. Check for ongoing EKS platform events in the AWS Health Dashboard.
4. If etcd-related, check if the cluster is hitting etcd storage limits.
5. Open an AWS Support case if health checks are persistently failing — this indicates control plane instability.

---

## 4. API Throttling (429s)

**What it detects:** The API server rejecting requests with HTTP 429 (Too Many Requests) via API Priority and Fairness (APF).

**Why no metric covers this:** `apiserver_request_total{code="429"}` exists but provides no breakdown of which client, flow schema, or priority level is being throttled. The audit log contains the full request context.

**Log source:** `kube-apiserver-audit`

**Query:**
```
filter @logStream like /kube-apiserver-audit/
| filter responseStatus.code = 429
| stats count(*) as throttledRequests by bin(5m)
```

**Default threshold:** ≥ 10 throttled requests in a 5-minute window

**Tuning guidance:**
- Large clusters with many controllers may see occasional 429s; raise to 50 if normal baseline is elevated.
- Lower to 5 for critical clusters where any throttling indicates capacity issues.

**Response runbook:**
1. From alarm log lines, identify the throttled user agent and request URI.
2. Check APF configuration: `kubectl get flowschemas` and `kubectl get prioritylevelconfigurations`.
3. Identify the noisy client and evaluate whether it can reduce request rate.
4. Consider creating a dedicated FlowSchema with higher concurrency shares for legitimate high-volume clients.
5. If system-wide, evaluate cluster sizing or splitting workloads.

---

## 5. PDB Eviction Blocked

**What it detects:** Pod eviction attempts repeatedly blocked by PodDisruptionBudgets.

**Why no metric covers this:** There is no metric for "eviction denied by PDB." The only signal is the 4xx response on the eviction subresource in audit logs.

**Log source:** `kube-apiserver-audit`

**Query:**
```
filter @logStream like /kube-apiserver-audit/
| filter objectRef.subresource = "eviction"
| filter responseStatus.code >= 400
| filter @message like /Cannot evict pod/ or @message like /disruption budget/
| stats count(*) as blockedEvictions by bin(5m)
```

**Default threshold:** ≥ 5 blocked evictions in a 5-minute window

**Tuning guidance:**
- Raise during planned maintenance windows when blocked evictions are expected.
- Lower to 1 if PDB blocks are causing upgrade timeouts.

**Response runbook:**
1. Identify the pod and PDB from the audit log message.
2. Check PDB status: `kubectl get pdb -A` — look for `ALLOWED DISRUPTIONS: 0`.
3. Determine if replicas can be scaled up to satisfy the PDB before retrying drain.
4. If the PDB is overly strict (e.g., `minAvailable` equals replica count), adjust the PDB policy.
5. For stuck node drains, consider temporarily relaxing the PDB or deleting the blocking pod manually.

---

## 6. Sustained Auth Denied

**What it detects:** Repeated authentication denials in the EKS authenticator — IAM identities that cannot be mapped to Kubernetes users.

**Why no metric covers this:** No CloudWatch metric reports authentication denial rate or which identity is being denied. The authenticator stream is the only source.

**Log source:** `authenticator`

**Query:**
```
filter @logStream like /authenticator/
| filter @message like /denied/ or @message like /Unauthorized/ or @message like /access denied/
| stats count(*) as authDenials by bin(5m)
```

**Default threshold:** ≥ 10 denials in a 5-minute window

**Tuning guidance:**
- Raise for clusters where CI/CD pipelines periodically rotate credentials (transient denials expected).
- Lower to 3 for security-sensitive clusters to detect brute-force probing early.

**Response runbook:**
1. Extract the denied IAM ARN from the authenticator log lines.
2. Verify the identity exists in `aws-auth` ConfigMap or EKS access entries.
3. Check if credentials are expired or the IAM role/user was recently deleted.
4. If unauthorized access attempt, investigate the source IP and consider restricting cluster endpoint access.
5. Update `aws-auth` or access entries if a legitimate identity was misconfigured.

---

## 7. Noisy Client List Storms

**What it detects:** Excessive LIST requests hitting the API server, which put load on etcd and can degrade cluster performance for all users.

**Why no metric covers this:** `apiserver_request_total{verb="list"}` exists but has no per-client breakdown. You cannot determine which user agent or service account is hammering the API without audit logs.

**Log source:** `kube-apiserver-audit`

**Query:**
```
filter @logStream like /kube-apiserver-audit/
| filter verb = "list"
| filter requestURI like /\/api\/v1\/pods/ or requestURI like /\/api\/v1\/namespaces/
| stats count(*) as listCalls by bin(5m)
```

**Default threshold:** ≥ 500 list calls in a 5-minute window

**Tuning guidance:**
- Heavily monitored clusters (Datadog, Dynatrace, etc.) may have a high baseline; calibrate by observing normal traffic first.
- Consider lowering to 200 for small clusters with few controllers.

**Response runbook:**
1. Query audit logs to identify the top user agents: group by `userAgent` or `user.username`.
2. Determine if the client is using informers/watches (efficient) or polling lists (inefficient).
3. Contact the team owning the noisy client to add label selectors or switch to watch-based patterns.
4. If a third-party tool, check for configuration to reduce polling frequency.
5. As a stopgap, apply APF FlowSchema to rate-limit the offending client.

---

## 8. Startup Probe Failures

**What it detects:** Containers stuck in startup probe failure loops, blocking pods from becoming ready and stalling rollouts.

**Why no metric covers this:** `kube_pod_container_status_waiting_reason` shows CrashLoopBackOff generically but doesn't distinguish startup probe failures from other restart reasons, and provides no per-container message detail.

**Log source:** `kube-apiserver-audit` (event creation)

**Query:**
```
filter @logStream like /kube-apiserver-audit/
| filter objectRef.resource = "events"
| filter requestObject.message like /Startup probe failed/
| stats count(*) as probeFailures by bin(5m)
```

**Default threshold:** ≥ 20 probe failures in a 5-minute window

**Tuning guidance:**
- Raise during deployment windows if slow-starting applications are expected.
- Lower to 5 for clusters running only fast-starting microservices.

**Response runbook:**
1. Identify the failing pod/container from the event message in the alarm notification.
2. Check pod status: `kubectl describe pod <pod-name>` — look at the startup probe configuration.
3. Verify the probe endpoint is correct and the application starts within the allowed window.
4. Increase `failureThreshold` or `periodSeconds` if the application legitimately needs more startup time.
5. Check for resource starvation (CPU throttling, slow image pulls) delaying container startup.
