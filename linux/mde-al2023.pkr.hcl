packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.9"
    }
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "packer_instance_profile" {
  type    = string
  default = "mde-packer-ssm"
}

data "amazon-ami" "al2023" {
  region      = var.region
  owners      = ["amazon"]
  most_recent = true

  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    architecture        = "x86_64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
}

source "amazon-ebs" "mde" {
  region               = var.region
  source_ami           = data.amazon-ami.al2023.id
  instance_type        = "t3.small"
  ssh_username         = "ec2-user"
  ssh_interface        = "session_manager"
  iam_instance_profile = var.packer_instance_profile
  ami_name             = "mde-al2023-x86_64-{{timestamp}}"
  ami_description      = "Amazon Linux 2023 with un-onboarded Microsoft Defender for Endpoint"
  imds_support         = "v2.0"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name         = "mde-al2023-golden"
    OS           = "Amazon Linux 2023"
    Architecture = "x86_64"
    MDEState     = "un-onboarded"
  }

  snapshot_tags = {
    Name = "mde-al2023-golden"
  }
}

build {
  sources = ["source.amazon-ebs.mde"]

  provisioner "file" {
    source      = "${path.root}/assets/mdatp_managed.json.tmpl"
    destination = "/tmp/mdatp_managed.json.tmpl"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/validate_mde_unonboarded.py"
    destination = "/tmp/validate_mde_unonboarded.py"
  }

  provisioner "shell" {
    execute_command = "sudo -S env {{ .Vars }} {{ .Path }}"
    inline = [
      "set -euo pipefail",
      "rpm --import https://packages.microsoft.com/keys/microsoft.asc",
      "curl -fsSL https://packages.microsoft.com/config/amazonlinux/2023/prod.repo -o /etc/yum.repos.d/microsoft-prod.repo",
      "dnf install -y mdatp",
      "HEALTH_CHECKED=false; for ATTEMPT in $(seq 1 12); do HEALTH_RAW=$(mdatp health --output json 2>&1 || true); if HEALTH_STATE=$(printf '%s' \"$HEALTH_RAW\" | python3 /tmp/validate_mde_unonboarded.py); then HEALTH_CHECKED=true; break; fi; sleep 5; done; test \"$HEALTH_CHECKED\" = true || { echo 'FAIL: MDE JSON health did not confirm licensed=false and org_id unavailable'; exit 1; }",
      "echo \"INFO: $HEALTH_STATE\"; echo 'PASS: package is un-onboarded'",
      "systemctl stop mdatp || true",
      "systemctl disable mdatp",
      "install -d -m 0755 /etc/opt/microsoft/mdatp/managed /opt/lab",
      "install -o root -g root -m 0644 /tmp/mdatp_managed.json.tmpl /opt/lab/mdatp_managed.json.tmpl",
      "rm -f /tmp/validate_mde_unonboarded.py",
      "rm -f /etc/opt/microsoft/mdatp/managed/mdatp_managed.json",
      "rm -rf /var/log/microsoft/mdatp/*",
      "dnf clean all",
      "rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*",
      "test ! -e /etc/opt/microsoft/mdatp/managed/mdatp_managed.json && echo 'PASS: no live managed profile' || { echo 'FAIL: live managed profile exists'; exit 1; }",
      "test -f /opt/lab/mdatp_managed.json.tmpl && echo 'PASS: staged managed profile template exists' || { echo 'FAIL: staged template missing'; exit 1; }",
      "MDATP_ENABLED=$(systemctl is-enabled mdatp 2>/dev/null || true); echo \"INFO: mdatp systemd state=<$MDATP_ENABLED>\"; test \"$MDATP_ENABLED\" = disabled && echo 'PASS: mdatp disabled' || { echo 'FAIL: mdatp is not disabled'; exit 1; }"
    ]
  }
}
