# The AWS implementation moved into compute/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = module.preflight
  to   = module.aws.module.preflight
}

moved {
  from = terraform_data.taint
  to   = module.aws.terraform_data.taint
}

moved {
  from = aws_instance.tenant
  to   = module.aws.aws_instance.tenant
}

moved {
  from = aws_ssm_parameter.instance
  to   = module.aws.aws_ssm_parameter.instance
}

moved {
  from = aws_iam_role.eks_cluster
  to   = module.aws.aws_iam_role.eks_cluster
}

moved {
  from = aws_iam_role_policy_attachment.eks_cluster_policy
  to   = module.aws.aws_iam_role_policy_attachment.eks_cluster_policy
}

moved {
  from = aws_iam_role_policy_attachment.eks_vpc_resource_controller
  to   = module.aws.aws_iam_role_policy_attachment.eks_vpc_resource_controller
}

moved {
  from = aws_iam_role.eks_node_group
  to   = module.aws.aws_iam_role.eks_node_group
}

moved {
  from = aws_iam_role_policy_attachment.eks_node_worker_policy
  to   = module.aws.aws_iam_role_policy_attachment.eks_node_worker_policy
}

moved {
  from = aws_iam_role_policy_attachment.eks_node_cni_policy
  to   = module.aws.aws_iam_role_policy_attachment.eks_node_cni_policy
}

moved {
  from = aws_iam_role_policy_attachment.eks_node_container_registry
  to   = module.aws.aws_iam_role_policy_attachment.eks_node_container_registry
}

moved {
  from = aws_eks_cluster.cluster
  to   = module.aws.aws_eks_cluster.cluster
}

moved {
  from = aws_eks_node_group.node_group
  to   = module.aws.aws_eks_node_group.node_group
}

moved {
  from = aws_iam_role.ebs_csi_driver
  to   = module.aws.aws_iam_role.ebs_csi_driver
}

moved {
  from = aws_iam_role_policy_attachment.ebs_csi_driver
  to   = module.aws.aws_iam_role_policy_attachment.ebs_csi_driver
}

moved {
  from = aws_eks_pod_identity_association.ebs_csi_driver
  to   = module.aws.aws_eks_pod_identity_association.ebs_csi_driver
}

moved {
  from = aws_iam_role.pod_identity
  to   = module.aws.aws_iam_role.pod_identity
}

moved {
  from = aws_iam_role_policy.pod_identity
  to   = module.aws.aws_iam_role_policy.pod_identity
}

moved {
  from = aws_eks_pod_identity_association.pod_identity
  to   = module.aws.aws_eks_pod_identity_association.pod_identity
}

moved {
  from = aws_eks_addon.addon
  to   = module.aws.aws_eks_addon.addon
}

moved {
  from = null_resource.kubeconfig_manager
  to   = module.aws.null_resource.kubeconfig_manager
}

moved {
  from = aws_ecs_cluster.cluster
  to   = module.aws.aws_ecs_cluster.cluster
}

moved {
  from = null_resource.k8s_namespaces
  to   = module.aws.null_resource.k8s_namespaces
}

moved {
  from = null_resource.helm_release
  to   = module.aws.null_resource.helm_release
}

moved {
  from = aws_lb.eks_service
  to   = module.aws.aws_lb.eks_service
}

moved {
  from = aws_lb_target_group.eks_service
  to   = module.aws.aws_lb_target_group.eks_service
}

moved {
  from = aws_lb_listener.eks_service
  to   = module.aws.aws_lb_listener.eks_service
}

moved {
  from = aws_autoscaling_attachment.eks_service
  to   = module.aws.aws_autoscaling_attachment.eks_service
}

moved {
  from = aws_security_group_rule.nlb_to_nodeport
  to   = module.aws.aws_security_group_rule.nlb_to_nodeport
}

moved {
  from = aws_security_group.alb
  to   = module.aws.aws_security_group.alb
}

moved {
  from = aws_security_group_rule.instance_ingress_from_alb
  to   = module.aws.aws_security_group_rule.instance_ingress_from_alb
}

moved {
  from = aws_lb.ec2_https
  to   = module.aws.aws_lb.ec2_https
}

moved {
  from = aws_lb_target_group.ec2_https
  to   = module.aws.aws_lb_target_group.ec2_https
}

moved {
  from = aws_lb_target_group_attachment.ec2_https
  to   = module.aws.aws_lb_target_group_attachment.ec2_https
}

moved {
  from = aws_lb_listener.ec2_https
  to   = module.aws.aws_lb_listener.ec2_https
}

moved {
  from = aws_lb_listener_rule.ec2_https
  to   = module.aws.aws_lb_listener_rule.ec2_https
}

moved {
  from = aws_lb_listener_rule.ec2_alias
  to   = module.aws.aws_lb_listener_rule.ec2_alias
}

moved {
  from = aws_lb_listener.ec2_http_redirect
  to   = module.aws.aws_lb_listener.ec2_http_redirect
}

moved {
  from = aws_route53_record.ec2_https
  to   = module.aws.aws_route53_record.ec2_https
}

moved {
  from = aws_route53_record.ec2_http
  to   = module.aws.aws_route53_record.ec2_http
}

moved {
  from = aws_route53_record.alias_https
  to   = module.aws.aws_route53_record.alias_https
}

moved {
  from = aws_route53_record.alias_http
  to   = module.aws.aws_route53_record.alias_http
}

moved {
  from = aws_security_group.class
  to   = module.aws.aws_security_group.class
}

moved {
  from = aws_security_group_rule.cluster_intra
  to   = module.aws.aws_security_group_rule.cluster_intra
}

moved {
  from = aws_security_group_rule.class_ingress
  to   = module.aws.aws_security_group_rule.class_ingress
}
