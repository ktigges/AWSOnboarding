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
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  description = "AWS region for the Windows pilot"
  default     = "us-west-2"
}

variable "ec2_instance_name" {
  type        = string
  description = "Name tag applied to the Windows EC2 instance"
  default     = "mde-windows-lab"

  validation {
    condition     = length(trimspace(var.ec2_instance_name)) > 0 && length(var.ec2_instance_name) <= 255
    error_message = "ec2_instance_name must be non-empty and at most 255 characters."
  }
}

variable "instance_type" {
  type        = string
  description = "Low-cost Windows pilot instance type"
  default     = "t3.small"
}

variable "administrator_public_key" {
  type        = string
  description = "RSA public key used by EC2 to encrypt the Windows Administrator password"
  sensitive   = true

  validation {
    condition     = can(regex("^ssh-rsa [A-Za-z0-9+/=]+( .*)?$", trimspace(var.administrator_public_key)))
    error_message = "administrator_public_key must be a valid ssh-rsa public key."
  }
}

variable "mde_device_tag" {
  type        = string
  description = "Fallback MDE Group tag and EC2 discovery tag"
  default     = "mde-windows-lab-test"

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
  description = "Derive account-id plus MdeTagSuffix from IMDSv2"
  default     = true
}

variable "mde_device_tag_suffix" {
  type        = string
  description = "Suffix used when deriving the MDE tag"
  default     = "windows-lab"

  validation {
    condition = (
      length(trimspace(var.mde_device_tag_suffix)) > 0 &&
      length(var.mde_device_tag_suffix) <= 187 &&
      length(regexall("[,()]", var.mde_device_tag_suffix)) == 0
    )
    error_message = "mde_device_tag_suffix must be non-empty, at most 187 characters, and contain no commas or parentheses."
  }
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

data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

locals {
  name                   = "mde-windows-lab"
  onboarding_script_path = "${path.module}/WindowsDefenderATPOnboardingScript.cmd"
}

resource "aws_s3_bucket" "onboarding" {
  bucket_prefix = "mde-windows-onboarding-${data.aws_caller_identity.current.account_id}-"
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
  key                    = "WindowsDefenderATPOnboardingScript.cmd"
  source                 = local.onboarding_script_path
  source_hash            = fileexists(local.onboarding_script_path) ? filemd5(local.onboarding_script_path) : null
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
  name = "read-mde-windows-package"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = aws_s3_object.onboarding.arn
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_key_pair" "administrator" {
  key_name_prefix = "${local.name}-"
  public_key      = trimspace(var.administrator_public_key)
}

resource "aws_security_group" "instance" {
  name_prefix = "${local.name}-"
  description = "Outbound access for SSM and MDE; no inbound access"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

resource "aws_ssm_document" "onboard" {
  name            = "MDE-Windows-Onboard"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure and onboard Windows Server 2022 to MDE"
    parameters = {
      MdeDeviceTag = {
        type              = "String"
        interpolationType = "ENV_VAR"
      }
      DeriveAtBoot = {
        type              = "String"
        allowedValues     = ["true", "false"]
        interpolationType = "ENV_VAR"
      }
      TagSuffix = {
        type              = "String"
        interpolationType = "ENV_VAR"
      }
      OnboardingS3Url = {
        type              = "String"
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [
      {
        action = "aws:runPowerShellScript"
        name   = "prepareOnboardingDirectory"
        inputs = {
          timeoutSeconds = "60"
          runCommand = [
            "$ErrorActionPreference = 'Stop'",
            "New-Item -ItemType Directory -Path 'C:\\ProgramData\\MDELab' -Force | Out-Null"
          ]
        }
      },
      {
        action = "aws:downloadContent"
        name   = "downloadOnboardingPackage"
        inputs = {
          sourceType      = "S3"
          sourceInfo      = "{\"path\":\"{{ OnboardingS3Url }}\"}"
          destinationPath = "C:\\ProgramData\\MDELab\\WindowsDefenderATPOnboardingScript.cmd"
          onFailure       = "exit"
        }
      },
      {
        action = "aws:runPowerShellScript"
        name   = "configureAndOnboard"
        inputs = {
          timeoutSeconds = "1800"
          runCommand = [
            "$ErrorActionPreference = 'Stop'",
            "$labRoot = 'C:\\ProgramData\\MDELab'",
            "New-Item -ItemType Directory -Path $labRoot -Force | Out-Null",
            "Start-Transcript -Path (Join-Path $labRoot 'bootstrap.log') -Append",
            "$mdeTag = $env:SSM_MdeDeviceTag",
            "if ($env:SSM_DeriveAtBoot -eq 'true') { $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{'X-aws-ec2-metadata-token-ttl-seconds'='21600'}; $headers = @{'X-aws-ec2-metadata-token'=$token}; $identity = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers $headers; $suffix = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/tags/instance/MdeTagSuffix' -Headers $headers; $mdeTag = \"$($identity.accountId)-$suffix\" }",
            "if ([string]::IsNullOrWhiteSpace($mdeTag) -or $mdeTag.Length -gt 200 -or $mdeTag -match '[,()]') { throw 'Invalid MDE device tag' }",
            "$tagKey = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows Advanced Threat Protection\\DeviceTagging'",
            "New-Item -Path $tagKey -Force | Out-Null",
            "New-ItemProperty -Path $tagKey -Name Group -PropertyType String -Value $mdeTag -Force | Out-Null",
            "$defaultExclusion = 'C:\\Managed\\default-exclude'",
            "$policyExclusions = @('C:\\Managed\\policy-exclude1', 'C:\\Managed\\policy-exclude2')",
            "@($defaultExclusion) + $policyExclusions | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }",
            "Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableArchiveScanning $false -DisableBlockAtFirstSeen $false -MAPSReporting Advanced -SubmitSamplesConsent SendSafeSamples -PUAProtection Enabled -CheckForSignaturesBeforeRunningScan $true -Force",
            "if ((Get-MpPreference).ExclusionPath -notcontains $defaultExclusion) { Add-MpPreference -ExclusionPath $defaultExclusion -Force }",
            "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0",
            "Set-Service -Name TermService -StartupType Automatic",
            "Start-Service -Name TermService",
            "$statusKey = 'HKLM:\\SOFTWARE\\Microsoft\\Windows Advanced Threat Protection\\Status'",
            "$onboardingState = (Get-ItemProperty -Path $statusKey -Name OnboardingState -ErrorAction SilentlyContinue).OnboardingState",
            "$script = Join-Path $labRoot 'WindowsDefenderATPOnboardingScript.cmd'",
            "if ($onboardingState -eq 1) { Write-Output 'MDE is already onboarded; skipping onboarding script' } elseif (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw \"Onboarding script not found: $script\" } else { Write-Output \"Using onboarding script: $script\"; $process = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $script -Wait -PassThru -NoNewWindow; if ($process.ExitCode -ne 0) { throw \"MDE onboarding failed with exit code $($process.ExitCode)\" } }",
            "Start-Service -Name Sense",
            "$onboardingState = (Get-ItemProperty -Path $statusKey -Name OnboardingState -ErrorAction Stop).OnboardingState",
            "if ($onboardingState -ne 1) { throw \"Unexpected MDE onboarding state: $onboardingState\" }",
            "if ((Get-Service -Name Sense).Status -ne 'Running') { throw 'Sense service is not running' }",
            "if ((Get-Service -Name WinDefend).Status -ne 'Running') { throw 'WinDefend service is not running' }",
            "$configuredTag = (Get-ItemProperty -Path $tagKey -Name Group -ErrorAction Stop).Group",
            "if ($configuredTag -ne $mdeTag) { throw \"Unexpected MDE Group tag: $configuredTag\" }",
            "$preferences = Get-MpPreference",
            "if ($preferences.ExclusionPath -notcontains $defaultExclusion) { throw 'Default local exclusion is missing' }",
            "foreach ($path in $policyExclusions) { if ($preferences.ExclusionPath -contains $path) { throw \"Policy test path must not be locally excluded: $path\" } }",
            "$protection = Get-MpComputerStatus",
            "if (-not $protection.AMServiceEnabled -or -not $protection.AntivirusEnabled -or -not $protection.BehaviorMonitorEnabled -or -not $protection.RealTimeProtectionEnabled) { throw 'Required Defender protection is not enabled' }",
            "if ($null -ne $script) { Remove-Item -Path $script -Force -ErrorAction SilentlyContinue }",
            "$protection | Select-Object AMServiceEnabled,AntivirusEnabled,BehaviorMonitorEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated",
            "$preferences | Select-Object ExclusionPath,MAPSReporting,SubmitSamplesConsent,PUAProtection",
            "Write-Output \"Verified MDE Group tag: $configuredTag\"",
            "$tagSyncMarker = Join-Path $labRoot 'tag-sync-reboot.txt'",
            "$lastRebootedTag = if (Test-Path $tagSyncMarker) { (Get-Content -Path $tagSyncMarker -Raw).Trim() } else { '' }",
            "if ($lastRebootedTag -ne $mdeTag) { Set-Content -Path $tagSyncMarker -Value $mdeTag -Encoding ASCII -Force; Write-Output 'Scheduling one reboot so MDE publishes the Windows registry tag immediately'; shutdown.exe /r /t 60 /d p:4:1 /c \"Publish MDE device tag\" } else { Write-Output 'Tag synchronization reboot already completed for this value' }",
            "Stop-Transcript"
          ]
        }
      }
    ]
  })
}

resource "aws_instance" "lab" {
  ami                         = data.aws_ssm_parameter.windows_ami.value
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  key_name                    = aws_key_pair.administrator.key_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name         = var.ec2_instance_name
    MdeDeviceTag = var.mde_device_tag
    MdeTagSuffix = var.mde_device_tag_suffix
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.onboarding_read,
    aws_s3_object.onboarding,
    aws_ssm_document.onboard
  ]
}

resource "aws_ssm_association" "onboard" {
  name                        = aws_ssm_document.onboard.name
  association_name            = "mde-windows-lab-onboard"
  apply_only_at_cron_interval = false

  targets {
    key    = "InstanceIds"
    values = [aws_instance.lab.id]
  }

  parameters = {
    MdeDeviceTag    = var.mde_device_tag
    DeriveAtBoot    = tostring(var.derive_mde_device_tag)
    TagSuffix       = var.mde_device_tag_suffix
    OnboardingS3Url = "https://${aws_s3_bucket.onboarding.id}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.onboarding.key}"
  }
}

output "instance_id" {
  value = aws_instance.lab.id
}

output "instance_name" {
  value = var.ec2_instance_name
}

output "windows_ami_id" {
  value = nonsensitive(data.aws_ssm_parameter.windows_ami.value)
}

output "onboarding_bucket" {
  value = aws_s3_bucket.onboarding.id
}

output "onboarding_association_id" {
  value = aws_ssm_association.onboard.association_id
}

output "public_ip" {
  value = aws_instance.lab.public_ip
}

output "rdp_tunnel_command" {
  value = "aws ssm start-session --target ${aws_instance.lab.id} --region ${var.aws_region} --document-name AWS-StartPortForwardingSession --parameters portNumber=3389,localPortNumber=13389"
}