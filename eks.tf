# =============================================================================
# CLOUDKITCHEN – EKS CLUSTER
# =============================================================================

locals {
  eks_cluster_name = "${local.env_prefix}-eks"
}

# ── 1. IAM — Cluster control-plane role ──────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${local.env_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.global_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── 2. IAM — Node group (worker nodes) role ───────────────────────────────────

resource "aws_iam_role" "eks_nodes" {
  name = "${local.env_prefix}-eks-nodes-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.global_tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Allows nodes to pull images from ECR (used by all 4 microservices)
resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Lets the CloudWatch agent / Fluent Bit (Container Insights add-on) push
# container metrics and logs to CloudWatch using the node role.
resource "aws_iam_role_policy_attachment" "eks_nodes_cloudwatch" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ── 3. EKS Cluster ───────────────────────────────────────────────────────────

resource "aws_eks_cluster" "cloudkitchen" {
  name     = local.eks_cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    # Control plane in all private app subnets + public subnets for kubectl access
    subnet_ids = concat(
      [for s in aws_subnet.public : s.id],
      [for s in aws_subnet.private_app : s.id],
    )
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Capture control-plane logs for debugging during review
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
  tags       = var.global_tags
}

# Allow EKS pods to reach RDS. Pods egress via the cluster security group, so
# RDS must accept :5432 from it. Managed in Terraform so it's recreated on every
# apply and torn down in the right order on destroy (no manual CLI rule needed).
resource "aws_security_group_rule" "eks_to_db" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db_sg.id
  source_security_group_id = aws_eks_cluster.cloudkitchen.vpc_config[0].cluster_security_group_id
  description              = "PostgreSQL from EKS pods (cluster SG)"
}

# ── 4. Managed Node Group ─────────────────────────────────────────────────────

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.cloudkitchen.name
  node_group_name = "${local.env_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  # Nodes run in private subnets — traffic reaches them via the internal LB
  subnet_ids = [for s in aws_subnet.private_app : s.id]

  instance_types = ["t3.medium"] # 2 vCPU / 4 GB — fits all 4 small services
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  tags = var.global_tags
}

# ── 5. EKS Core Add-ons ───────────────────────────────────────────────────────

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.cloudkitchen.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
  tags                        = var.global_tags
}

# Container Insights: CloudWatch agent + Fluent Bit (cluster/pod metrics + logs).
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.cloudkitchen.name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main, aws_iam_role_policy_attachment.eks_nodes_cloudwatch]
  tags                        = var.global_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.cloudkitchen.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
  tags                        = var.global_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.cloudkitchen.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
  tags                        = var.global_tags
}


# ── 6. Subnet tags required for AWS Load Balancer Controller ──────────────────
# Public subnets: external (internet-facing) ALB
# Private app subnets: internal ALB / services

resource "aws_ec2_tag" "public_subnet_elb" {
  for_each    = { for idx, s in aws_subnet.public : tostring(idx) => s }
  resource_id = each.value.id
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

resource "aws_ec2_tag" "public_subnet_cluster" {
  for_each    = { for idx, s in aws_subnet.public : tostring(idx) => s }
  resource_id = each.value.id
  key         = "kubernetes.io/cluster/${local.eks_cluster_name}"
  value       = "shared"
}

resource "aws_ec2_tag" "private_subnet_internal_elb" {
  for_each    = { for idx, s in aws_subnet.private_app : tostring(idx) => s }
  resource_id = each.value.id
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

resource "aws_ec2_tag" "private_subnet_cluster" {
  for_each    = { for idx, s in aws_subnet.private_app : tostring(idx) => s }
  resource_id = each.value.id
  key         = "kubernetes.io/cluster/${local.eks_cluster_name}"
  value       = "shared"
}
