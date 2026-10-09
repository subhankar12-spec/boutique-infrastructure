data "aws_availability_zones" "available" { state = "available" }
locals {
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = merge(var.tags, { Project = "boutique", Environment = var.name, ManagedBy = "terraform" })
}
module "vpc" {
  source                                          = "terraform-aws-modules/vpc/aws"
  version                                         = "5.21.0"
  name                                            = var.name
  cidr                                            = var.vpc_cidr
  azs                                             = local.azs
  private_subnets                                 = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets                                  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
  database_subnets                                = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  create_database_subnet_group                    = true
  enable_nat_gateway                              = true
  single_nat_gateway                              = !var.production
  one_nat_gateway_per_az                          = var.production
  enable_dns_hostnames                            = true
  enable_dns_support                              = true
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = local.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.logs.arn
  private_subnet_tags                             = { "kubernetes.io/role/internal-elb" = "1" }
  public_subnet_tags                              = { "kubernetes.io/role/elb" = "1" }
  tags                                            = local.tags
}
resource "aws_kms_key" "platform" {
  description             = "${var.name} encrypted platform data"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}
resource "aws_kms_alias" "platform" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.platform.key_id
}
resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}
resource "aws_eks_cluster" "this" {
  name                      = var.name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config { authentication_mode = "API" }
  vpc_config {
    subnet_ids              = module.vpc.private_subnets
    endpoint_private_access = true
    endpoint_public_access  = false
  }
  encryption_config {
    provider { key_arn = aws_kms_key.platform.arn }
    resources = ["secrets"]
  }
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.eks]
  tags       = local.tags
}
resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.admin]
}
resource "aws_iam_role" "nodes" {
  name               = "${var.name}-eks-nodes"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "nodes" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryReadOnly", "AmazonEKS_CNI_Policy"])
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.name}-"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 40
      volume_type = "gp3"
      encrypted   = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }
}
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "application"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = module.vpc.private_subnets
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count + 2
  }
  update_config { max_unavailable = 1 }
  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
  depends_on = [aws_iam_role_policy_attachment.nodes]
  tags       = local.tags
}
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.this]
}
resource "aws_eks_addon" "core" {
  for_each                    = toset(["coredns", "kube-proxy", "eks-pod-identity-agent"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_update = "PRESERVE"
  depends_on                  = [aws_eks_node_group.this]
}
data "tls_certificate" "oidc" { url = aws_eks_cluster.this.identity[0].oidc[0].issuer }
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = local.tags
}
resource "aws_security_group" "data" {
  name_prefix = "${var.name}-data-"
  vpc_id      = module.vpc.vpc_id
  description = "Database access from this EKS cluster only"
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "redis" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}
resource "aws_db_instance" "orders" {
  for_each                        = var.environments
  identifier                      = "${var.name}-${each.key}-orders"
  engine                          = "postgres"
  engine_version                  = "16"
  instance_class                  = var.production ? "db.t4g.medium" : "db.t4g.micro"
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.platform.arn
  db_name                         = "boutique"
  username                        = "boutique_admin"
  manage_master_user_password     = true
  master_user_secret_kms_key_id   = aws_kms_key.platform.arn
  multi_az                        = var.production
  db_subnet_group_name            = module.vpc.database_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.data.id]
  publicly_accessible             = false
  backup_retention_period         = var.production ? 14 : 3
  backup_window                   = "03:00-04:00"
  maintenance_window              = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade      = true
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${var.name}-${each.key}-orders-final"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  depends_on                      = [aws_cloudwatch_log_group.orders]
  tags                            = merge(local.tags, { Environment = each.key })
}
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name}-redis"
  subnet_ids = module.vpc.database_subnets
}
resource "random_password" "redis" {
  for_each = var.environments
  length   = 40
  special  = false
}
resource "random_password" "session" {
  for_each = var.environments
  length   = 64
  special  = false
}
resource "random_password" "database" {
  for_each = var.environments
  length   = 40
  special  = false
}
resource "aws_elasticache_replication_group" "redis" {
  for_each                   = var.environments
  replication_group_id       = "${var.name}-${each.key}-cart"
  description                = "${each.key} isolated carts"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.production ? "cache.t4g.small" : "cache.t4g.micro"
  num_cache_clusters         = var.production ? 2 : 1
  automatic_failover_enabled = var.production
  multi_az_enabled           = var.production
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.data.id]
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.platform.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis[each.key].result
  dynamic "log_delivery_configuration" {
    for_each = toset(["slow-log", "engine-log"])
    content {
      destination      = aws_cloudwatch_log_group.redis["${each.key}/${log_delivery_configuration.value}"].name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = log_delivery_configuration.value
    }
  }
  snapshot_retention_limit = var.production ? 7 : 1
  tags                     = merge(local.tags, { Environment = each.key })
}
resource "aws_secretsmanager_secret" "application" {
  for_each                = var.environments
  name                    = "${var.name}/${each.key}/application"
  kms_key_id              = aws_kms_key.platform.arn
  recovery_window_in_days = 30
  tags                    = merge(local.tags, { Environment = each.key })
}
resource "aws_secretsmanager_secret_version" "application" {
  for_each  = var.environments
  secret_id = aws_secretsmanager_secret.application[each.key].id
  secret_string = jsonencode({
    session_secret    = random_password.session[each.key].result,
    redis_url         = "rediss://:${random_password.redis[each.key].result}@${aws_elasticache_replication_group.redis[each.key].primary_endpoint_address}:6379/0",
    database_url      = "jdbc:postgresql://${aws_db_instance.orders[each.key].address}:5432/boutique?sslmode=verify-full&sslrootcert=/app/certs/global-bundle.pem",
    database_username = "boutique",
    database_password = random_password.database[each.key].result
  })
}
resource "aws_iam_role" "external_secrets" {
  for_each = var.environments
  name     = "${var.name}-${each.key}-external-secrets"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }, Action = "sts:AssumeRoleWithWebIdentity", Condition = { StringEquals = {
    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:boutique-${each.key}:external-secrets",
    "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
  } } }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "external_secrets" {
  for_each = var.environments
  role     = aws_iam_role.external_secrets[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = aws_secretsmanager_secret.application[each.key].arn },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = aws_kms_key.platform.arn }
  ] })
}
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$boutique"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
