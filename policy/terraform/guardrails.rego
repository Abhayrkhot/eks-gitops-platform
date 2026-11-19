# Plan-time guardrails for every Terraform change. CI runs
#   terraform show -json plan.tfplan > plan.json
#   conftest test plan.json --policy policy/terraform --data policy/data
# and blocks the pull request on any deny. Each message starts with a rule ID
# (TFnnn) that the fixture suite in experiments/policy asserts on.
package main

g := data.guardrails

world := {"0.0.0.0/0", "::/0"}

# ------------------------------------------------------------------ helpers
changing contains rc if {
	some rc in input.resource_changes
	some action in rc.change.actions
	action in {"create", "update"}
}

deleting contains rc if {
	some rc in input.resource_changes
	"delete" in rc.change.actions
}

as_list(x) := x if is_array(x)

as_list(x) := [x] if is_string(x)

as_list(x) := [] if is_null(x)

as_list(x) := [] if is_number(x)

after_field(rc, name) := object.get(rc.change.after, name, null)

is_unknown(rc, name) if rc.change.after_unknown[name] == true

env(rc) := object.get(object.get(rc.change.after, "tags_all", {}), "Environment", "")

# Environment stacks (infra, gitops) declare var.environment; bootstrap does not.
is_env_stack if input.variables.environment.value

is_local(rc) if env(rc) == "local"

minor(v) := to_number(split(v, ".")[1])

statements(doc) := doc.Statement if is_array(doc.Statement)

statements(doc) := [doc.Statement] if is_object(doc.Statement)

policy_doc(rc, name) := json.unmarshal(after_field(rc, name)) if is_string(after_field(rc, name))

public_port(from, to, proto) if {
	proto in {"tcp", "6"}
	from == to
	from in g.public_ports
}

# ------------------------------------------------------- network exposure
deny contains msg if {
	some rc in changing
	rc.type == "aws_security_group"
	some rule in as_list(after_field(rc, "ingress"))
	some cidr in array.concat(as_list(object.get(rule, "cidr_blocks", [])), as_list(object.get(rule, "ipv6_cidr_blocks", [])))
	cidr in world
	not public_port(rule.from_port, rule.to_port, rule.protocol)
	msg := sprintf("TF001 %s: ingress from %s on ports %v-%v (%v); only %v may be public", [rc.address, cidr, rule.from_port, rule.to_port, rule.protocol, g.public_ports])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_security_group_rule"
	after_field(rc, "type") == "ingress"
	some cidr in array.concat(as_list(after_field(rc, "cidr_blocks")), as_list(after_field(rc, "ipv6_cidr_blocks")))
	cidr in world
	not public_port(after_field(rc, "from_port"), after_field(rc, "to_port"), after_field(rc, "protocol"))
	msg := sprintf("TF001 %s: ingress from %s on ports %v-%v; only %v may be public", [rc.address, cidr, after_field(rc, "from_port"), after_field(rc, "to_port"), g.public_ports])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_vpc_security_group_ingress_rule"
	some cidr in array.concat(as_list(after_field(rc, "cidr_ipv4")), as_list(after_field(rc, "cidr_ipv6")))
	cidr in world
	not public_port(after_field(rc, "from_port"), after_field(rc, "to_port"), after_field(rc, "ip_protocol"))
	msg := sprintf("TF001 %s: ingress from %s on ports %v-%v; only %v may be public", [rc.address, cidr, after_field(rc, "from_port"), after_field(rc, "to_port"), g.public_ports])
}

# ------------------------------------------------------------------- EKS
open_endpoint(vpc) if {
	some c in as_list(object.get(vpc, "public_access_cidrs", null))
	c in world
}

open_endpoint(vpc) if count(as_list(object.get(vpc, "public_access_cidrs", null))) == 0

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	vpc := after_field(rc, "vpc_config")[0]
	vpc.endpoint_public_access == true
	open_endpoint(vpc)
	msg := sprintf("TF002 %s: public API endpoint open to the internet; restrict public_access_cidrs", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	object.get(after_field(rc, "access_config")[0], "authentication_mode", "") != "API"
	msg := sprintf("TF003 %s: authentication_mode must be API (no aws-auth ConfigMap)", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	not "audit" in as_list(after_field(rc, "enabled_cluster_log_types"))
	msg := sprintf("TF004 %s: control-plane audit logging must stay enabled", [rc.address])
}

support_type(rc) := after_field(rc, "upgrade_policy")[0].support_type

# EKS defaults to EXTENDED when no upgrade policy is set. The local emulator
# cannot store the policy, so only there may it be absent.
deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	support_type(rc) == "EXTENDED"
	msg := sprintf("TF005 %s: upgrade_policy.support_type must be STANDARD (extended support costs 6x)", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	not is_local(rc)
	not support_type(rc)
	msg := sprintf("TF005 %s: no upgrade_policy, so EKS defaults to EXTENDED support (6x cost)", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	v := after_field(rc, "version")
	is_string(v)
	not v in g.supported_kubernetes_versions
	msg := sprintf("TF006 %s: Kubernetes %s is not a supported version %v", [rc.address, v, g.supported_kubernetes_versions])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	"update" in rc.change.actions
	before := minor(rc.change.before.version)
	after := minor(rc.change.after.version)
	after < before
	msg := sprintf("TF006 %s: Kubernetes downgrade %s -> %s is not possible", [rc.address, rc.change.before.version, rc.change.after.version])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_cluster"
	"update" in rc.change.actions
	minor(rc.change.after.version) - minor(rc.change.before.version) > 1
	msg := sprintf("TF006 %s: upgrade %s -> %s skips a minor version", [rc.address, rc.change.before.version, rc.change.after.version])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_node_group"
	some it in as_list(after_field(rc, "instance_types"))
	not it in g.allowed_instance_types
	msg := sprintf("TF007 %s: instance type %s is not in the allowlist %v", [rc.address, it, g.allowed_instance_types])
}

deny contains msg if {
	some rc in changing
	rc.type in {"aws_instance", "aws_launch_template"}
	it := after_field(rc, "instance_type")
	is_string(it)
	it != "" # launch templates for managed node groups leave the type to the node group
	not it in g.allowed_instance_types
	msg := sprintf("TF007 %s: instance type %s is not in the allowlist %v", [rc.address, it, g.allowed_instance_types])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_node_group"
	max_size := after_field(rc, "scaling_config")[0].max_size
	max_size > g.max_node_group_size
	msg := sprintf("TF008 %s: max_size %v exceeds the cap of %v nodes", [rc.address, max_size, g.max_node_group_size])
}

deny contains msg if {
	some rc in deleting
	rc.type == "aws_eks_addon"
	rc.change.before.addon_name in g.critical_addons
	msg := sprintf("TF021 %s: removing the %s add-on breaks cluster networking/DNS", [rc.address, rc.change.before.addon_name])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_eks_access_policy_association"
	endswith(after_field(rc, "policy_arn"), "/AmazonEKSClusterAdminPolicy")
	principal := after_field(rc, "principal_arn")
	is_string(principal)
	not admin_principal_allowed(principal)
	msg := sprintf("TF022 %s: cluster-admin for %s; only %v roles may be cluster admins", [rc.address, principal, g.cluster_admin_principal_patterns])
}

admin_principal_allowed(p) if {
	some pattern in g.cluster_admin_principal_patterns
	contains(p, pattern)
}

# ---------------------------------------------------------------- compute
deny contains msg if {
	some rc in changing
	rc.type == "aws_launch_template"
	not imdsv2(rc)
	msg := sprintf("TF019 %s: instance metadata must require IMDSv2 tokens", [rc.address])
}

imdsv2(rc) if after_field(rc, "metadata_options")[0].http_tokens == "required"

deny contains msg if {
	some rc in changing
	rc.type == "aws_launch_template"
	some bdm in as_list(after_field(rc, "block_device_mappings"))
	some ebs in as_list(object.get(bdm, "ebs", []))
	object.get(ebs, "encrypted", "false") != "true"
	msg := sprintf("TF020 %s: EBS volume %s is not encrypted", [rc.address, bdm.device_name])
}

# ------------------------------------------------------------------- S3
deny contains msg if {
	some rc in changing
	rc.type == "aws_s3_bucket_public_access_block"
	some flag in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	after_field(rc, flag) != true
	msg := sprintf("TF009 %s: %s must be true", [rc.address, flag])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_s3_bucket_acl"
	after_field(rc, "acl") in {"public-read", "public-read-write", "authenticated-read"}
	msg := sprintf("TF009 %s: public bucket ACL %s", [rc.address, after_field(rc, "acl")])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_s3_bucket_policy"
	doc := policy_doc(rc, "policy")
	some st in statements(doc)
	st.Effect == "Allow"
	st.Principal in {"*", {"AWS": "*"}}
	not st.Condition
	msg := sprintf("TF009 %s: bucket policy allows anonymous access", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_s3_bucket_versioning"
	after_field(rc, "versioning_configuration")[0].status != "Enabled"
	msg := sprintf("TF010 %s: state bucket versioning must stay Enabled", [rc.address])
}

deny contains msg if {
	some rc in deleting
	rc.type in {"aws_s3_bucket_versioning", "aws_s3_bucket_server_side_encryption_configuration", "aws_s3_bucket_public_access_block"}
	msg := sprintf("TF010 %s: removing a state-bucket protection (%s)", [rc.address, rc.type])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_s3_bucket"
	after_field(rc, "force_destroy") == true
	bucket := after_field(rc, "bucket")
	contains(bucket, "tfstate")
	not endswith(bucket, "-local")
	msg := sprintf("TF010 %s: force_destroy on a state bucket lets one destroy delete every environment's state", [rc.address])
}

# ------------------------------------------------------------------- IAM
grant_policy_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

is_boundary(rc) if {
	rc.type == "aws_iam_policy"
	endswith(after_field(rc, "name"), "-boundary")
}

deny contains msg if {
	some rc in changing
	rc.type in grant_policy_types
	not is_boundary(rc)
	doc := policy_doc(rc, "policy")
	some st in statements(doc)
	st.Effect == "Allow"
	some action in as_list(object.get(st, "Action", []))
	action in {"*", "iam:*", "*:*"}
	"*" in as_list(object.get(st, "Resource", []))
	msg := sprintf("TF011 %s: grants %s on every resource", [rc.address, action])
}

deny contains msg if {
	some rc in changing
	rc.type in {"aws_iam_role_policy_attachment", "aws_iam_user_policy_attachment", "aws_iam_group_policy_attachment", "aws_iam_policy_attachment"}
	arn := after_field(rc, "policy_arn")
	some suffix in g.admin_policy_suffixes
	endswith(arn, suffix)
	msg := sprintf("TF012 %s: attaches %s", [rc.address, arn])
}

deny contains msg if {
	some rc in changing
	rc.type in {"aws_iam_user", "aws_iam_access_key", "aws_iam_user_login_profile"}
	msg := sprintf("TF013 %s: long-lived IAM users/keys are not allowed; use roles and OIDC", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_iam_role"
	is_env_stack
	not is_unknown(rc, "permissions_boundary")
	not is_string(after_field(rc, "permissions_boundary"))
	msg := sprintf("TF014 %s: role has no permissions boundary", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_iam_role"
	doc := policy_doc(rc, "assume_role_policy")
	some st in statements(doc)
	st.Effect == "Allow"
	st.Principal in {"*", {"AWS": "*"}}
	msg := sprintf("TF015 %s: trust policy lets any AWS principal assume the role", [rc.address])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_iam_role"
	doc := policy_doc(rc, "assume_role_policy")
	some st in statements(doc)
	st.Effect == "Allow"
	endswith(object.get(object.get(st, "Principal", {}), "Federated", ""), "token.actions.githubusercontent.com")
	not github_sub_pinned(st)
	msg := sprintf("TF015 %s: GitHub OIDC trust must pin the sub claim to this repository", [rc.address])
}

github_sub_pinned(st) if {
	some op in ["StringEquals", "StringLike"]
	subs := as_list(object.get(object.get(object.get(st, "Condition", {}), op, {}), "token.actions.githubusercontent.com:sub", null))
	count(subs) > 0
	every s in subs {
		startswith(s, "repo:")
		not startswith(s, "repo:*")
		not contains(split(s, ":")[1], "*")
	}
}

required_boundary_sids := {
	"DenyLongLivedCredentials", "DenyRolesWithoutBoundary", "DenyBoundaryRemoval",
	"DenyBoundaryTampering", "DenyAdminPolicyAttachment", "DenyStateBucketTampering",
	"DenyAuditTampering", "DenyOutsideAllowedRegions",
}

deny contains msg if {
	some rc in changing
	is_boundary(rc)
	doc := policy_doc(rc, "policy")
	sids := {st.Sid | some st in statements(doc); st.Effect == "Deny"}
	missing := required_boundary_sids - sids
	count(missing) > 0
	msg := sprintf("TF024 %s: permissions boundary lost deny statements %v", [rc.address, sort(missing)])
}

# --------------------------------------------------- destructive changes
deny contains msg if {
	some rc in deleting
	rc.type in g.protected_types
	verb := replace_or_delete(rc)
	msg := sprintf("TF016 %s: plan would %s a protected %s; this needs a reviewed break-glass change", [rc.address, verb, rc.type])
}

replace_or_delete(rc) := "replace" if "create" in rc.change.actions

replace_or_delete(rc) := "delete" if not "create" in rc.change.actions

# ------------------------------------------------------------- hygiene
deny contains msg if {
	some rc in changing
	is_env_stack
	tags := after_field(rc, "tags_all")
	is_object(tags)
	some tag in g.required_tags
	not tags[tag]
	msg := sprintf("TF017 %s: missing required tag %s", [rc.address, tag])
}

deny contains msg if {
	region := input.variables.region.value
	not region in g.allowed_regions
	msg := sprintf("TF018 plan targets region %s; allowed: %v", [region, g.allowed_regions])
}

deny contains msg if {
	some rc in changing
	rc.type == "aws_cloudwatch_log_group"
	object.get(rc.change.after, "retention_in_days", 0) == 0
	msg := sprintf("TF023 %s: log group never expires; set retention_in_days", [rc.address])
}
