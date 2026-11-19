# Unit tests for the guardrails (`conftest verify`). The end-to-end proof is
# the fixture suite, which feeds real plans; these pin the edge cases.
package main

import data.guardrails

mkrc(type, actions, after) := {
	"address": sprintf("%s.test", [type]),
	"type": type,
	"change": {"actions": actions, "before": null, "after": after, "after_unknown": {}},
}

plan(changes) := {"resource_changes": changes, "variables": {"region": {"value": "us-east-2"}}}

has(rule, msgs) if {
	some m in msgs
	startswith(m, rule)
}

test_ssh_from_world_denied if {
	sg := mkrc("aws_security_group", ["create"], {"ingress": [{"from_port": 22, "to_port": 22, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"]}]})
	has("TF001", deny) with input as plan([sg])
}

test_https_from_world_allowed if {
	sg := mkrc("aws_security_group", ["create"], {"ingress": [{"from_port": 443, "to_port": 443, "protocol": "tcp", "cidr_blocks": ["0.0.0.0/0"]}]})
	not has("TF001", deny) with input as plan([sg])
}

test_endpoint_without_cidrs_denied if {
	c := mkrc("aws_eks_cluster", ["create"], {
		"vpc_config": [{"endpoint_public_access": true, "public_access_cidrs": []}],
		"access_config": [{"authentication_mode": "API"}],
		"enabled_cluster_log_types": ["audit"],
		"upgrade_policy": [{"support_type": "STANDARD"}],
		"version": "1.34",
	})
	has("TF002", deny) with input as plan([c])
}

test_private_cluster_clean if {
	c := mkrc("aws_eks_cluster", ["create"], {
		"vpc_config": [{"endpoint_public_access": false}],
		"access_config": [{"authentication_mode": "API"}],
		"enabled_cluster_log_types": ["audit"],
		"upgrade_policy": [{"support_type": "STANDARD"}],
		"version": "1.34",
	})
	count(deny) == 0 with input as plan([c])
}

test_one_minor_upgrade_allowed_two_denied if {
	base := {
		"vpc_config": [{"endpoint_public_access": false}],
		"access_config": [{"authentication_mode": "API"}],
		"enabled_cluster_log_types": ["audit"],
		"upgrade_policy": [{"support_type": "STANDARD"}],
	}
	one := object.union(mkrc("aws_eks_cluster", ["update"], object.union(base, {"version": "1.35"})), {"change": {"actions": ["update"], "before": {"version": "1.34"}, "after": object.union(base, {"version": "1.35"}), "after_unknown": {}}})
	two := object.union(mkrc("aws_eks_cluster", ["update"], object.union(base, {"version": "1.35"})), {"change": {"actions": ["update"], "before": {"version": "1.33"}, "after": object.union(base, {"version": "1.35"}), "after_unknown": {}}})
	not has("TF006", deny) with input as plan([one])
	has("TF006", deny) with input as plan([two])
}

test_boundary_policy_exempt_from_wildcard_rule if {
	b := mkrc("aws_iam_policy", ["create"], {
		"name": "eks-gitops-boundary",
		"policy": json.marshal({"Statement": [{"Effect": "Allow", "Action": ["iam:*"], "Resource": "*"}]}),
	})
	not has("TF011", deny) with input as plan([b])
}

test_github_trust_wildcard_repo_denied if {
	r := mkrc("aws_iam_role", ["create"], {"assume_role_policy": json.marshal({"Statement": [{
		"Effect": "Allow",
		"Principal": {"Federated": "arn:aws:iam::1:oidc-provider/token.actions.githubusercontent.com"},
		"Action": "sts:AssumeRoleWithWebIdentity",
		"Condition": {"StringLike": {"token.actions.githubusercontent.com:sub": ["repo:*:pull_request"]}},
	}]})})
	has("TF015", deny) with input as plan([r])
}

test_github_trust_pinned_repo_allowed if {
	r := mkrc("aws_iam_role", ["create"], {"assume_role_policy": json.marshal({"Statement": [{
		"Effect": "Allow",
		"Principal": {"Federated": "arn:aws:iam::1:oidc-provider/token.actions.githubusercontent.com"},
		"Action": "sts:AssumeRoleWithWebIdentity",
		"Condition": {"StringLike": {"token.actions.githubusercontent.com:sub": ["repo:acme/infra:pull_request"]}},
	}]})})
	not has("TF015", deny) with input as plan([r])
}

test_replace_of_vpc_denied if {
	v := mkrc("aws_vpc", ["delete", "create"], {"cidr_block": "10.1.0.0/16"})
	has("TF016", deny) with input as plan([v])
}

test_data_loaded if {
	count(guardrails.allowed_regions) > 0
}
