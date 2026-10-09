# KMS encryption key and alias for platform data.

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
