# Security

## Reporting a Vulnerability

If you discover a potential security issue in this project, we ask that you notify
AWS/Amazon Security via our
[vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/)
or directly via email to [aws-security@amazon.com](mailto:aws-security@amazon.com).
Please do **not** create a public GitHub issue for security findings.

## AWS Services Used

This solution deploys and interacts with the following AWS services:

- **Amazon CloudWatch** — Log Alarms running scheduled Logs Insights queries
- **Amazon CloudWatch Logs** — EKS control plane log group (read-only queries)
- **AWS IAM** — two least-privilege roles (scheduled query execution, log line retrieval), scoped to the specific EKS log group ARN
- **AWS KMS** — customer-managed key encrypting the SNS topic at rest (created only when the stack creates the topic)
- **Amazon SNS** — alarm notification delivery
- **Amazon EKS** — the monitored cluster (this solution only reads its logs; the optional prerequisite template creates a demo cluster)

## Known Security Considerations

- **Non-production sample.** This code is for demonstration and education. Review and
  adapt it to your own security requirements before any production use.
- **Demo cluster networking.** `examples/prerequisite-cluster.yaml` creates a disposable
  test cluster with public subnets and auto-assigned public IPs to avoid NAT gateway
  costs. Do not use this network layout outside disposable test accounts.
- **Test scripts create failure conditions.** Scripts under `tests/` intentionally
  deploy failing webhooks, drain nodes, create a temporary unmapped IAM role, and
  apply a temporary API Priority and Fairness throttle. Run them only against
  disposable test clusters with cluster-admin access you control.
- **Bring-your-own SNS topic.** If you pass `ExistingSNSTopicARN` for a topic encrypted
  with a customer-managed KMS key, the key policy must grant `cloudwatch.amazonaws.com`
  the `kms:Decrypt` and `kms:GenerateDataKey*` permissions or notifications will fail.

## Production Hardening Recommendations

Before adapting this solution for production use:

- Deploy EKS clusters into private subnets with restricted API endpoint access;
  do not reuse the demo prerequisite template.
- Review and tune alarm thresholds against your cluster's observed baseline.
- Restrict SNS topic subscriptions and consider routing alarms through EventBridge
  to your incident management system.
- Consider extracting the inline IAM policies into customer-managed policies if your
  organization audits IAM with shared tooling (e.g., IAM Access Analyzer).
- Apply your organization's tagging, logging, and change-management standards to
  the CloudFormation stack.

## Cleanup

To remove all resources created by this solution:

1. Remove test conditions (if you ran the test scripts): `./tests/cleanup.sh <cluster-name>`
2. Delete the alarms stack: `./examples/teardown.sh <cluster-name> [region]`
3. If you deployed the demo cluster, delete its stack:
   `aws cloudformation delete-stack --stack-name <cluster-stack-name>`

The KMS key created by the stack is deleted with the stack (KMS enforces a mandatory
waiting period before final key deletion).
