"""
SSM Compliance Callback Plugin for Ansible

Tracks per-host task results and pushes compliance data to AWS SSM
via PutComplianceItems after playbook execution completes.

ComplianceType: Custom:AnsiblePlaybook
Status: COMPLIANT if 0 failures, NON_COMPLIANT otherwise

Environment variables (set by orchestrator):
    COMPLIANCE_SEVERITY - CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL, UNSPECIFIED
    CODEBUILD_BUILD_ID - CodeBuild build ID for traceability
    PLAYBOOK_NAME - Name of the playbook being executed
    AWS_REGION - AWS region for SSM API calls
"""

import datetime
import os

from ansible.plugins.callback import CallbackBase

try:
    import boto3
    HAS_BOTO3 = True
except ImportError:
    HAS_BOTO3 = False


DOCUMENTATION = r"""
name: ssm_compliance
type: notification
short_description: Push per-host results to SSM Compliance
description:
  - Tracks per-host task results (ok, changed, failed, skipped).
  - On playbook completion, calls ssm:PutComplianceItems for each host.
requirements:
  - boto3
"""


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "notification"
    CALLBACK_NAME = "ssm_compliance"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.host_results = {}
        self.playbook_name = os.environ.get("PLAYBOOK_NAME", "unknown")
        self.build_id = os.environ.get("CODEBUILD_BUILD_ID", "local")
        self.severity = os.environ.get("COMPLIANCE_SEVERITY", "HIGH")
        self.region = os.environ.get("AWS_REGION", "us-east-1")

    def _track_result(self, host, status):
        if host not in self.host_results:
            self.host_results[host] = {
                "ok": 0, "changed": 0, "failed": 0,
                "skipped": 0, "unreachable": 0
            }
        self.host_results[host][status] += 1

    def v2_runner_on_ok(self, result, **kwargs):
        host = result._host.get_name()
        if result._result.get("changed", False):
            self._track_result(host, "changed")
        else:
            self._track_result(host, "ok")

    def v2_runner_on_failed(self, result, ignore_errors=False, **kwargs):
        if not ignore_errors:
            self._track_result(result._host.get_name(), "failed")

    def v2_runner_on_skipped(self, result, **kwargs):
        self._track_result(result._host.get_name(), "skipped")

    def v2_runner_on_unreachable(self, result, **kwargs):
        self._track_result(result._host.get_name(), "unreachable")

    def v2_playbook_on_stats(self, stats):
        """Push compliance items to SSM after playbook completes."""
        if not HAS_BOTO3:
            self._display.warning(
                "ssm_compliance: boto3 not available, skipping compliance push"
            )
            return

        if not self.host_results:
            self._display.display("ssm_compliance: No host results to report")
            return

        try:
            ssm = boto3.client("ssm", region_name=self.region)
        except Exception as e:
            self._display.warning(f"ssm_compliance: Failed to create SSM client: {e}")
            return

        now = datetime.datetime.utcnow()

        for host, counts in self.host_results.items():
            is_compliant = counts["failed"] == 0 and counts["unreachable"] == 0
            status = "COMPLIANT" if is_compliant else "NON_COMPLIANT"

            task_summary = (
                f"ok={counts['ok']} changed={counts['changed']} "
                f"failed={counts['failed']} skipped={counts['skipped']} "
                f"unreachable={counts['unreachable']}"
            )

            items = [
                {
                    "Id": self.playbook_name,
                    "Title": f"Ansible Playbook: {self.playbook_name}",
                    "Severity": self.severity,
                    "Status": status,
                    "Details": {
                        "DocumentName": self.playbook_name,
                        "DocumentVersion": self.build_id,
                        "Classification": "AnsiblePlaybook",
                        "DetailedText": task_summary,
                    },
                }
            ]

            try:
                ssm.put_compliance_items(
                    ResourceId=host,
                    ResourceType="ManagedInstance",
                    ComplianceType="Custom:AnsiblePlaybook",
                    ExecutionSummary={
                        "ExecutionTime": now,
                        "ExecutionId": self.build_id,
                        "ExecutionType": "Command",
                    },
                    Items=items,
                )
                self._display.display(
                    f"ssm_compliance: {host} -> {status} "
                    f"(ok={counts['ok']} changed={counts['changed']} "
                    f"failed={counts['failed']} skipped={counts['skipped']})"
                )
            except Exception as e:
                self._display.warning(
                    f"ssm_compliance: Failed to push compliance for {host}: {e}"
                )
