# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.


## Adding a New Alarm Pattern

### 1. Design the Query

Start by testing your Logs Insights query in the CloudWatch console:

1. Go to CloudWatch → Logs Insights
2. Select the relevant EKS log group(s)
3. Write and test your query
4. Verify it returns meaningful results for the failure mode you're targeting

**Query guidelines:**
- Use specific `filter` clauses to avoid false positives
- Include `stats count(*) as <metricName> by bin(5m)` for aggregation
- Test with both "quiet" and "noisy" time periods
- Consider using `parse` to extract structured fields for richer context

### 2. Add to the CloudFormation Template

Add your alarm resource to `template.yaml`:

1. Add a parameter for the enable toggle:
```yaml
EnableMyNewAlarm:
  Type: String
  Default: "true"
  AllowedValues: ["true", "false"]
  Description: Enable alarm for <your pattern description>
```

2. Add a condition:
```yaml
MyNewAlarmEnabled: !Equals [!Ref EnableMyNewAlarm, "true"]
```

3. Add the alarm resource following the existing pattern structure. Set the
   `Threshold` directly on the alarm resource (thresholds are per-alarm values
   in this template, not parameters) and reuse the shared schedule/evaluation
   parameters (`QuerySchedule`, `LookbackWindowSeconds`, `EvaluationPeriods`,
   `DatapointsToAlarm`).

### 3. Document the Pattern

Add an entry to `docs/alarm-patterns.md` with:
- What it detects
- Why it matters
- The query with explanation
- Default threshold and tuning guidance
- Response runbook

### 4. Update the README

Add a row to the alarm table in `README.md`.

## Testing

Before submitting:

1. **Validate the template:**
```bash
aws cloudformation validate-template --template-body file://template.yaml
```

2. **Deploy to a test cluster:**
```bash
./examples/deploy.sh <test-cluster-name> your-email@example.com
```

3. **Verify alarms appear** (requires AWS CLI v2.36+ for the LogAlarm type):
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "<cluster-name>-" \
  --alarm-types LogAlarm
```

4. **Trigger the condition** (if possible in a test environment) and verify the alarm transitions to ALARM state. Add a trigger function for your alarm to `tests/trigger.sh` and matching removal steps to `tests/cleanup.sh` — every test must be cleanly reversible.

## Code Style

- Use consistent YAML indentation (2 spaces)
- Include `AlarmDescription` that explains the alarm to an on-call engineer at 3 AM
- Always include both `AlarmActions` and `OKActions`
- Set `TreatMissingData: notBreaching` unless there's a specific reason not to
- Include `ActionLogLineCount` for context in notifications


## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The version of our code being used
* Any modifications you've made relevant to the bug
* Anything unusual about your environment or deployment


## Contributing via Pull Requests
Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local tests pass.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).


## Finding contributions to work on
Looking at the existing issues is a great way to find something to contribute on. As our projects, by default, use the default GitHub issue labels (enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any 'help wanted' issues is a great place to start.


## Code of Conduct
This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.


## Security issue notifications
If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public github issue.


## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.
