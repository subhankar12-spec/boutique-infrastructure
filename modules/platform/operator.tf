data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
resource "aws_iam_role" "operator" {
  name               = "${var.name}-operator"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "operator" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "operator" {
  name = "${var.name}-operator"
  role = aws_iam_role.operator.name
}
resource "aws_security_group" "operator" {
  name_prefix = "${var.name}-operator-"
  vpc_id      = module.vpc.vpc_id
  description = "SSM-only operator; no inbound rules"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "operator_eks" {
  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.operator.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
resource "aws_instance" "operator" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.operator.id]
  iam_instance_profile   = aws_iam_instance_profile.operator.name
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 12
  }
  tags = merge(local.tags, { Name = "${var.name}-operator" })
}
output "operator_instance_id" { value = aws_instance.operator.id }

resource "aws_vpc_security_group_ingress_rule" "operator_postgres" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.operator.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
