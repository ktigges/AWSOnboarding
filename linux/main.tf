terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

variable "ami_id" {
  type        = string
  description = "Un-onboarded AMI produced by Packer"
}

variable "ec2_instance_name" {
  type        = string
  description = "Name tag applied to the deployed EC2 instance"
  default     = "mde-linux-lab"

  validation {
    condition     = length(trimspace(var.ec2_instance_name)) > 0 && length(var.ec2_instance_name) <= 255
    error_message = "ec2_instance_name must be non-empty and at most 255 characters."
  }
}

variable "enable_ssh" {
  type        = bool
  description = "Enable direct SSH using a generated local key and a restricted source CIDR"
  default     = false
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "IPv4 CIDR allowed to connect to TCP 22"
  default     = ""

  validation {
    condition     = !var.enable_ssh || can(cidrnetmask(var.ssh_allowed_cidr))
    error_message = "ssh_allowed_cidr must be a valid IPv4 CIDR when SSH is enabled."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed for ec2-user when SSH is enabled"
  default     = ""
  sensitive   = true

  validation {
    condition = (
      !var.enable_ssh ||
      can(regex("^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    )
    error_message = "ssh_public_key must be a valid ssh-ed25519 or ssh-rsa public key when SSH is enabled."
  }
}

variable "mde_device_tag" {
  type        = string
  description = "MDE GROUP tag and EC2 discovery tag"
  default     = "mde-lab-test"

  validation {
    condition = (
      length(trimspace(var.mde_device_tag)) > 0 &&
      length(var.mde_device_tag) <= 200 &&
      length(regexall("[,()]", var.mde_device_tag)) == 0
    )
    error_message = "mde_device_tag must be non-empty, at most 200 characters, and contain no commas or parentheses."
  }
}

variable "derive_mde_device_tag" {
  type        = bool
  default     = false
  description = "Derive account-id plus MdeTagSuffix from IMDSv2 at boot"
}

variable "mde_device_tag_suffix" {
  type    = string
  default = "linux-lab"

  validation {
    condition = (
      length(trimspace(var.mde_device_tag_suffix)) > 0 &&
      length(var.mde_device_tag_suffix) <= 187 &&
      length(regexall("[,()]", var.mde_device_tag_suffix)) == 0
    )
    error_message = "mde_device_tag_suffix must be non-empty, at most 187 characters, and contain no commas or parentheses."
  }
}

variable "use_ssm_association" {
  type        = bool
  default     = true
  description = "Use State Manager. Set false for the user-data variant."
}

data "aws_caller_identity" "current" {}
data "aws_vpc" "default" {
  default = true
}
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  name = "mde-linux-lab"
}

resource "aws_s3_bucket" "onboarding" {
  bucket_prefix = "mde-linux-onboarding-${data.aws_caller_identity.current.account_id}-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "onboarding" {
  bucket                  = aws_s3_bucket.onboarding.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "onboarding" {
  bucket = aws_s3_bucket.onboarding.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "onboarding" {
  bucket = aws_s3_bucket.onboarding.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "onboarding" {
  bucket                 = aws_s3_bucket.onboarding.id
  key                    = "tenant/MicrosoftDefenderATPOnboardingLinuxServer.py"
  source                 = "${path.module}/MicrosoftDefenderATPOnboardingLinuxServer.py"
  source_hash            = filemd5("${path.module}/MicrosoftDefenderATPOnboardingLinuxServer.py")
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.onboarding,
    aws_s3_bucket_versioning.onboarding
  ]
}

resource "aws_s3_object" "managed_profile" {
  bucket                 = aws_s3_bucket.onboarding.id
  key                    = "config/mdatp_managed.json.tmpl"
  source                 = "${path.module}/assets/mdatp_managed.json.tmpl"
  source_hash            = filemd5("${path.module}/assets/mdatp_managed.json.tmpl")
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.onboarding,
    aws_s3_bucket_versioning.onboarding
  ]
}

resource "aws_iam_role" "instance" {
  name = "${local.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "onboarding_read" {
  name = "read-mde-onboarding-object"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject"]
      Resource = [
        aws_s3_object.onboarding.arn,
        aws_s3_object.managed_profile.arn
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name_prefix = "${local.name}-"
  description = "Outbound access for SSM and MDE with optional restricted SSH ingress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count             = var.enable_ssh ? 1 : 0
  security_group_id = aws_security_group.instance.id
  description       = "SSH from the configured administrator IPv4 address"
  cidr_ipv4         = var.ssh_allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_ssm_document" "onboard" {
  name            = "MDE-Linux-Onboard"
  document_type   = "Command"
  document_format = "JSON"

  content = file("${path.module}/ssm-document.json")
}

resource "aws_ssm_document" "ssh_access" {
  count           = var.enable_ssh ? 1 : 0
  name            = "MDE-Linux-Configure-SSH"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install the configured administrator SSH public key for ec2-user"
    parameters = {
      SshPublicKey = {
        type              = "String"
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "configureSshAccess"
      inputs = {
        timeoutSeconds = "300"
        runCommand = [
          "set -euo pipefail",
          "install -d -o ec2-user -g ec2-user -m 0700 /home/ec2-user/.ssh",
          "touch /home/ec2-user/.ssh/authorized_keys",
          "chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys",
          "chmod 0600 /home/ec2-user/.ssh/authorized_keys",
          "grep -qxF \"$SSM_SshPublicKey\" /home/ec2-user/.ssh/authorized_keys || printf '%s\\n' \"$SSM_SshPublicKey\" >> /home/ec2-user/.ssh/authorized_keys",
          "restorecon -RF /home/ec2-user/.ssh 2>/dev/null || true",
          "sshd -t",
          "systemctl enable --now sshd"
        ]
      }
    }]
  })
}

resource "aws_instance" "lab" {
  ami                         = var.ami_id
  instance_type               = "t3.small"
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  user_data = var.use_ssm_association ? null : templatefile("${path.module}/user-data.sh.tftpl", {
    mde_device_tag         = jsonencode(var.mde_device_tag)
    derive_at_boot         = var.derive_mde_device_tag
    mde_device_tag_suffix  = jsonencode(var.mde_device_tag_suffix)
    onboarding_s3_uri      = "s3://${aws_s3_bucket.onboarding.id}/${aws_s3_object.onboarding.key}"
    managed_profile_s3_uri = "s3://${aws_s3_bucket.onboarding.id}/${aws_s3_object.managed_profile.key}"
  })

  tags = {
    Name         = var.ec2_instance_name
    MdeDeviceTag = var.mde_device_tag
    MdeTagSuffix = var.mde_device_tag_suffix
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.onboarding_read,
    aws_s3_object.onboarding,
    aws_s3_object.managed_profile
  ]
}

resource "aws_ssm_association" "onboard" {
  count                       = var.use_ssm_association ? 1 : 0
  name                        = aws_ssm_document.onboard.name
  association_name            = "mde-linux-lab-onboard"
  apply_only_at_cron_interval = false

  targets {
    key    = "InstanceIds"
    values = [aws_instance.lab.id]
  }

  parameters = {
    MdeDeviceTag        = var.mde_device_tag
    DeriveAtBoot        = tostring(var.derive_mde_device_tag)
    TagSuffix           = var.mde_device_tag_suffix
    OnboardingS3Uri     = "s3://${aws_s3_bucket.onboarding.id}/${aws_s3_object.onboarding.key}"
    ManagedProfileS3Uri = "s3://${aws_s3_bucket.onboarding.id}/${aws_s3_object.managed_profile.key}"
  }
}

resource "aws_ssm_association" "ssh_access" {
  count            = var.enable_ssh ? 1 : 0
  name             = aws_ssm_document.ssh_access[0].name
  association_name = "mde-linux-lab-ssh-access"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.lab.id]
  }

  parameters = {
    SshPublicKey = trimspace(var.ssh_public_key)
  }
}

output "instance_id" {
  value = aws_instance.lab.id
}

output "onboarding_bucket" {
  value = aws_s3_bucket.onboarding.id
}

output "session_command" {
  value = "aws ssm start-session --target ${aws_instance.lab.id} --region us-west-2"
}

output "public_ip" {
  value = aws_instance.lab.public_ip
}

output "ssh_association_id" {
  value = try(aws_ssm_association.ssh_access[0].association_id, null)
}
