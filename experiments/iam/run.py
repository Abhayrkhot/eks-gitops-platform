#!/usr/bin/env python3
"""Prove the CI IAM guardrails on a real AWS account.

The harness assumes the CI roles (through the bootstrap stack's break-glass
testing trust, `extra_trusted_principal_arns`) and makes real API calls that
an attacker, a compromised pipeline, or a careless change would make. Every
"unsafe" call must come back AccessDenied/UnauthorizedOperation; every
"control" call must still work, so the roles are not simply broken.

Calls are chosen so that nothing harmful happens even if a guardrail failed:
deletes target fakes or a throwaway tagged VPC, launches use --dry-run, and
anything that gets created is removed in `finally`.

    AWS_PROFILE=default uv run --with-requirements experiments/requirements.txt --with boto3 \
        experiments/iam/run.py --state-bucket <bucket>
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import uuid
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib import RESULTS, log, write_json  # noqa: E402

DENIED = {"AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedAccess",
          "AuthorizationError", "AuthFailure", "Forbidden"}
REGION = "us-east-1"
WORKLOAD_PATH = "/eks-gitops/"
EC2_TRUST = json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]})


def session_for(role_arn: str) -> boto3.Session:
    creds = boto3.client("sts").assume_role(RoleArn=role_arn, RoleSessionName="guardrail-test")["Credentials"]
    return boto3.Session(aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretAccessKey"],
                         aws_session_token=creds["SessionToken"], region_name=REGION)


def attempt(fn) -> tuple[str, str]:
    """Run fn; return (decision, detail). decision is denied | allowed | error."""
    try:
        fn()
        return "allowed", "ok"
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "DryRunOperation":
            return "allowed", "dry-run would succeed"
        if code in DENIED:
            return "denied", code
        # Any other error means IAM let the call through to the service.
        return "allowed", f"reached service: {code}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state-bucket", required=True)
    ap.add_argument("--apply-role", default="")
    ap.add_argument("--plan-role", default="")
    ap.add_argument("--env", default="aws")
    args = ap.parse_args()

    admin = boto3.Session(region_name=REGION)
    account = admin.client("sts").get_caller_identity()["Account"]
    apply_arn = args.apply_role or f"arn:aws:iam::{account}:role/eks-gitops-ci/eks-gitops-apply"
    plan_arn = args.plan_role or f"arn:aws:iam::{account}:role/eks-gitops-ci/eks-gitops-plan"
    boundary_arn = f"arn:aws:iam::{account}:policy/eks-gitops-ci/eks-gitops-boundary"
    bucket = args.state_bucket
    tag = uuid.uuid4().hex[:8]

    ap_s = session_for(apply_arn)
    pl_s = session_for(plan_arn)
    a_iam, a_s3, a_ec2 = ap_s.client("iam"), ap_s.client("s3"), ap_s.client("ec2")
    p_iam, p_s3, p_ec2 = pl_s.client("iam"), pl_s.client("s3"), pl_s.client("ec2")

    ami = admin.client("ssm").get_parameter(
        Name="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64")["Parameter"]["Value"]
    state_key = next((o["Key"] for o in admin.client("s3").list_objects_v2(Bucket=bucket).get("Contents", [])
                      if o["Key"].endswith(".tfstate")), "dev/infra.tfstate")

    # Throwaway resources the guardrails must protect.
    admin_ec2 = admin.client("ec2")
    protected_vpc = admin_ec2.create_vpc(CidrBlock="10.99.0.0/28", TagSpecifications=[{
        "ResourceType": "vpc", "Tags": [{"Key": "Protection", "Value": "protected"},
                                        {"Key": "Name", "Value": f"guardrail-test-{tag}"}]}])["Vpc"]["VpcId"]
    created_roles: list[tuple[boto3.client, str]] = []
    created_users: list[str] = []
    created_lock_keys: list[tuple[boto3.client, str]] = []

    def mk_role(client, name, path=WORKLOAD_PATH, boundary=True):
        kwargs = dict(RoleName=name, Path=path, AssumeRolePolicyDocument=EC2_TRUST)
        if boundary:
            kwargs["PermissionsBoundary"] = boundary_arn
        client.create_role(**kwargs)
        created_roles.append((admin.client("iam"), name))

    def mk_user(client, name):
        client.create_user(UserName=name)
        created_users.append(name)

    def put_lock(client, key):
        client.put_object(Bucket=bucket, Key=key, Body=b"{}")
        created_lock_keys.append((admin.client("s3"), key))

    control_role = f"gr-control-{tag}"
    checks = [
        # (id, role, description, expected, callable)
        ("I01", "apply", "create an IAM user", "denied", lambda: mk_user(a_iam, f"gr-user-{tag}")),
        ("I02", "apply", "create an access key for the admin user", "denied",
         lambda: a_iam.create_access_key(UserName="eks-gitops")),
        ("I03", "apply", "create a workload role without the boundary", "denied",
         lambda: mk_role(a_iam, f"gr-nobound-{tag}", boundary=False)),
        ("I04", "apply", "create a role outside the /eks-gitops/ path", "denied",
         lambda: mk_role(a_iam, f"gr-outside-{tag}", path="/")),
        ("C01", "apply", "CONTROL: create a workload role with the boundary", "allowed",
         lambda: mk_role(a_iam, control_role)),
        ("I05", "apply", "attach AdministratorAccess to a workload role", "denied",
         lambda: a_iam.attach_role_policy(RoleName=control_role, PolicyArn="arn:aws:iam::aws:policy/AdministratorAccess")),
        ("I06", "apply", "remove a workload role's permissions boundary", "denied",
         lambda: a_iam.delete_role_permissions_boundary(RoleName=control_role)),
        ("I07", "apply", "rewrite the permissions boundary policy", "denied",
         lambda: a_iam.create_policy_version(PolicyArn=boundary_arn, SetAsDefault=True, PolicyDocument=json.dumps(
             {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}))),
        ("I08", "apply", "widen its own trust policy", "denied",
         lambda: a_iam.update_assume_role_policy(RoleName="eks-gitops-apply", PolicyDocument=EC2_TRUST)),
        ("I09", "apply", "add an inline policy to itself", "denied",
         lambda: a_iam.put_role_policy(RoleName="eks-gitops-apply", PolicyName="escalate", PolicyDocument=json.dumps(
             {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "*", "Resource": "*"}]}))),
        ("I10", "apply", "delete the state bucket", "denied", lambda: a_s3.delete_bucket(Bucket=bucket)),
        ("I11", "apply", "suspend state bucket versioning", "denied",
         lambda: a_s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={"Status": "Suspended"})),
        ("I12", "apply", "remove the state bucket policy", "denied", lambda: a_s3.delete_bucket_policy(Bucket=bucket)),
        ("I13", "apply", "purge a state file version", "denied",
         lambda: a_s3.delete_object(Bucket=bucket, Key=state_key, VersionId="fakeversionid0000000000000000000")),
        ("I14", "apply", "launch a 96-vCPU instance (dry run)", "denied",
         lambda: a_ec2.run_instances(ImageId=ami, InstanceType="m5.24xlarge", MinCount=1, MaxCount=1, DryRun=True)),
        ("C02", "apply", "CONTROL: launch an approved instance type (dry run)", "allowed",
         lambda: a_ec2.run_instances(ImageId=ami, InstanceType="t3.small", MinCount=1, MaxCount=1, DryRun=True)),
        ("I15", "apply", "work in an unapproved region (eu-west-1)", "denied",
         lambda: ap_s.client("ec2", region_name="eu-west-1").describe_vpcs()),
        ("I16", "apply", "use a service outside the platform (RDS)", "denied",
         lambda: ap_s.client("rds").describe_db_instances()),
        ("I17", "apply", "use a service outside the platform (Lambda)", "denied",
         lambda: ap_s.client("lambda").list_functions()),
        ("I18", "apply", "stop CloudTrail logging", "denied",
         lambda: ap_s.client("cloudtrail").stop_logging(Name=f"arn:aws:cloudtrail:{REGION}:{account}:trail/none-{tag}")),
        ("I19", "apply", "delete a GuardDuty detector", "denied",
         lambda: ap_s.client("guardduty").delete_detector(DetectorId="0" * 32)),
        ("I20", "apply", "schedule a KMS key for deletion", "denied",
         lambda: ap_s.client("kms").schedule_key_deletion(KeyId=str(uuid.uuid4()), PendingWindowInDays=7)),
        ("I21", "apply", "read AWS Organizations", "denied",
         lambda: ap_s.client("organizations").list_accounts()),
        ("I22", "apply", "delete a VPC tagged Protection=protected", "denied",
         lambda: a_ec2.delete_vpc(VpcId=protected_vpc)),
        ("I23", "apply", "make a snapshot public", "denied",
         lambda: a_ec2.modify_snapshot_attribute(SnapshotId="snap-0123456789abcdef0", Attribute="createVolumePermission",
                                                  OperationType="add", GroupNames=["all"])),
        ("I24", "apply", "turn off account-wide S3 public access block", "denied",
         lambda: ap_s.client("s3control").delete_public_access_block(AccountId=account)),
        ("C03", "apply", "CONTROL: describe VPCs in the allowed region", "allowed", lambda: a_ec2.describe_vpcs()),
        ("I25", "plan", "create a VPC from a pull request", "denied",
         lambda: p_ec2.create_vpc(CidrBlock="10.98.0.0/28", DryRun=True)),
        ("I26", "plan", "overwrite a state file from a pull request", "denied",
         lambda: p_s3.put_object(Bucket=bucket, Key=state_key, Body=b"{}")),
        ("I27", "plan", "create an IAM role from a pull request", "denied",
         lambda: mk_role(p_iam, f"gr-plan-{tag}")),
        ("I28", "plan", "create an IAM user from a pull request", "denied", lambda: mk_user(p_iam, f"gr-plan-user-{tag}")),
        ("C04", "plan", "CONTROL: take the state lock", "allowed",
         lambda: put_lock(p_s3, f"guardrail-test/{tag}.tflock")),
        ("C05", "plan", "CONTROL: read the state file", "allowed",
         lambda: p_s3.get_object(Bucket=bucket, Key=state_key)),
    ]

    results = []
    try:
        for cid, role, desc, expected, fn in checks:
            decision, detail = attempt(fn)
            verdict = "PASS" if decision == expected else "FAIL"
            results.append({"id": cid, "role": role, "check": desc, "expected": expected,
                            "decision": decision, "detail": detail, "verdict": verdict})
            log(f"{cid} {role:5s} {verdict}  expected={expected:7s} got={decision:7s} ({detail})  {desc}")
    finally:
        aiam, as3 = admin.client("iam"), admin.client("s3")
        for client, name in created_roles:
            try:
                for p in aiam.list_attached_role_policies(RoleName=name)["AttachedPolicies"]:
                    aiam.detach_role_policy(RoleName=name, PolicyArn=p["PolicyArn"])
                aiam.delete_role(RoleName=name)
            except ClientError as e:
                if e.response["Error"]["Code"] != "NoSuchEntity":
                    log(f"cleanup role {name}: {e}")
        for name in created_users:
            try:
                aiam.delete_user(UserName=name)
            except ClientError:
                pass
        for client, key in created_lock_keys:
            versions = as3.list_object_versions(Bucket=bucket, Prefix=key).get("Versions", [])
            for v in versions:
                as3.delete_object(Bucket=bucket, Key=key, VersionId=v["VersionId"])
        admin_ec2.delete_vpc(VpcId=protected_vpc)

    unsafe = [r for r in results if r["expected"] == "denied"]
    controls = [r for r in results if r["expected"] == "allowed"]
    summary = {
        "env": args.env,
        "started": dt.datetime.now(dt.timezone.utc).isoformat(),
        "unsafe_calls": len(unsafe),
        "denied": sum(r["verdict"] == "PASS" for r in unsafe),
        "unsafe_allowed": [r["id"] for r in unsafe if r["verdict"] == "FAIL"],
        "controls": len(controls),
        "controls_allowed": sum(r["verdict"] == "PASS" for r in controls),
        "controls_broken": [r["id"] for r in controls if r["verdict"] == "FAIL"],
    }
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    write_json(RESULTS / args.env / f"iam-{stamp}.json", {"summary": summary, "checks": results})
    print(yaml.safe_dump(summary, sort_keys=False))
    sys.exit(0 if not (summary["unsafe_allowed"] or summary["controls_broken"]) else 1)


if __name__ == "__main__":
    main()
