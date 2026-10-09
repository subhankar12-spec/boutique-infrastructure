# VPC, subnet topology, routing configuration and shared data access rules.

data "aws_availability_zones" "available" { state = "available" }

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
