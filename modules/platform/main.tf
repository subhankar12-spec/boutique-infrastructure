# Shared values for the platform module.

locals {
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = merge(var.tags, { Project = "boutique", Environment = var.name, ManagedBy = "terraform" })
}
