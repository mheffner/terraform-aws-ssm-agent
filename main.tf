module "role_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  context    = module.this.context
  attributes = compact(concat(["role"], var.attributes))
}

module "logs_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  context    = module.this.context
  attributes = compact(concat(["logs"], var.attributes))
}

locals {
  region     = coalesce(var.region, data.aws_region.current.name)
  account_id = data.aws_caller_identity.current.account_id

  session_logging_bucket_name = try(coalesce(var.session_logging_bucket_name, module.logs_label.id), "")
  session_logging_kms_key_arn = try(coalesce(var.session_logging_kms_key_arn, module.kms_key.key_arn), "")

  logs_bucket_enabled = var.session_logging_enabled && length(var.session_logging_bucket_name) == 0
}

#####################
## SSM AGENT ROLE ##
###################

data "aws_iam_policy_document" "default" {

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_s3_bucket" "logs_bucket" {
  count  = var.session_logging_enabled ? 1 : 0
  bucket = try(coalesce(var.session_logging_bucket_name, module.logs_bucket.bucket_id), "")
}

# https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-create-iam-instance-profile.html#create-iam-instance-profile-ssn-logging
data "aws_iam_policy_document" "session_logging" {
  count = var.session_logging_enabled ? 1 : 0

  statement {
    sid    = "SSMAgentSessionAllowS3Logging"
    effect = "Allow"
    actions = [
      "s3:PutObject"
    ]
    resources = ["${join("", data.aws_s3_bucket.logs_bucket.*.arn)}/*"]
  }

  statement {
    sid    = "SSMAgentSessionAllowCloudWatchLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SSMAgentSessionAllowGetEncryptionConfig"
    effect = "Allow"
    actions = [
      "s3:GetEncryptionConfiguration"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SSMAgentSessionAllowKMSDataKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "default" {
  name                 = module.role_label.id
  assume_role_policy   = data.aws_iam_policy_document.default.json
  permissions_boundary = var.permissions_boundary
  tags                 = module.role_label.tags
}

resource "aws_iam_role_policy_attachment" "default" {
  role       = aws_iam_role.default.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "session_logging" {
  count = var.session_logging_enabled ? 1 : 0

  name   = "${module.role_label.id}-session-logging"
  role   = aws_iam_role.default.name
  policy = join("", data.aws_iam_policy_document.session_logging.*.json)
}

resource "aws_iam_instance_profile" "default" {
  name = module.role_label.id
  role = aws_iam_role.default.name
}

#####################
## SECURITY GROUP ##
###################

resource "aws_security_group" "default" {
  vpc_id      = var.vpc_id
  name        = module.this.id
  description = "Allow ALL egress from SSM Agent."
  tags        = module.this.tags
}

resource "aws_security_group_rule" "allow_all_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.default.id
}

#######################
## SECURITY LOGGING ##
#####################

module "kms_key" {
  source  = "cloudposse/kms-key/aws"
  version = "0.12.1"

  enabled = var.session_logging_enabled && var.session_logging_encryption_enabled && length(var.session_logging_kms_key_arn) == 0
  context = module.logs_label.context

  description             = "KMS key for encrypting Session Logs in S3 and CloudWatch."
  deletion_window_in_days = 10
  enable_key_rotation     = true
  alias                   = var.session_logging_kms_key_alias

  policy = <<DOC
{
  "Version" : "2012-10-17",
  "Id" : "${module.logs_label.id}-policy",
  "Statement" : [
    {
      "Sid" : "Enable IAM User Permissions",
      "Effect" : "Allow",
      "Principal" : {
        "AWS" : "arn:aws:iam::${local.account_id}:root"
      },
      "Action" : "kms:*",
      "Resource" : "*"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "logs.${local.region}.amazonaws.com"
      },
      "Action": [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
      ],
      "Resource": "*",
      "Condition": {
        "ArnLike": {
          "kms:EncryptionContext:aws:logs:arn": "arn:aws:logs:${local.region}:${local.account_id}:log-group:${module.logs_label.id}"
        }
      }
    }
  ]
}
DOC
}

module "logs_bucket" {
  source  = "cloudposse/s3-bucket/aws"
  version = "3.1.2"

  enabled = local.logs_bucket_enabled
  context = module.logs_label.context

  # Encryption / Security
  acl                          = "private"
  sse_algorithm                = "aws:kms"
  kms_master_key_arn           = local.session_logging_kms_key_arn
  allow_encrypted_uploads_only = false
  force_destroy                = true

  # Feature enablement
  user_enabled       = false
  versioning_enabled = true

  lifecycle_configuration_rules = [{
    enabled                                = true
    id                                     = module.logs_label.id
    abort_incomplete_multipart_upload_days = 90
    filter_and                             = null

    expiration = {
      days = 0
    }
    noncurrent_version_expiration = {
      noncurrent_days = 365
    }
    noncurrent_version_transition = [{
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }, ]
    transition = [{
      days          = 90
      storage_class = "GLACIER"
    }, ]
  }]
}

resource "aws_cloudwatch_log_group" "session_logging" {
  count = var.session_logging_enabled ? 1 : 0

  name              = module.logs_label.id
  retention_in_days = var.cloudwatch_retention_in_days
  kms_key_id        = var.session_logging_encryption_enabled ? local.session_logging_kms_key_arn : ""
  tags              = module.logs_label.tags
}

resource "aws_ssm_document" "session_logging" {
  count = var.session_logging_enabled && var.create_run_shell_document ? 1 : 0

  name          = var.session_logging_ssm_document_name
  document_type = "Session"
  tags          = module.logs_label.tags
  content       = <<DOC
{
  "schemaVersion": "1.0",
  "description": "Document to hold regional settings for Session Manager",
  "sessionType": "Standard_Stream",
  "inputs": {
    "s3BucketName": "${local.session_logging_bucket_name}",
    "s3KeyPrefix": "logs/",
    "s3EncryptionEnabled": true,
    "cloudWatchLogGroupName": "${module.this.id}",
    "cloudWatchEncryptionEnabled": true,
    "kmsKeyId": "${local.session_logging_kms_key_arn}",
    "runAsEnabled": false,
    "runAsDefaultUser": ""
  }
}
DOC
}

############################
## LAUNCH TEMPLATE + ASG ##
##########################

resource "aws_launch_template" "default" {
  name_prefix   = module.this.id
  image_id      = length(var.ami) > 0 ? var.ami : data.aws_ami.amazon_linux_2.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name
  user_data     = base64encode(var.user_data)

  monitoring {
    enabled = var.monitoring_enabled
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    delete_on_termination       = true
    security_groups             = concat(var.additional_security_group_ids, [aws_security_group.default.id])
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.default.name
  }

  tag_specifications {
    resource_type = "instance"
    tags          = module.this.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = module.this.tags
  }

  lifecycle {
    create_before_destroy = true
  }

  metadata_options {
    http_endpoint      = var.metadata_http_endpoint_enabled ? "enabled" : "disabled"
    http_tokens        = var.metadata_imdsv2_enabled ? "required" : "optional"
    http_protocol_ipv6 = var.metadata_http_protocol_ipv6_enabled ? "enabled" : "disabled"
  }
}

resource "aws_autoscaling_group" "default" {
  name_prefix = "${module.this.id}-asg"
  dynamic "tag" {
    for_each = module.this.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
  launch_template {
    id      = aws_launch_template.default.id
    version = "$Latest"
  }

  max_size         = var.instance_count
  min_size         = var.instance_count
  desired_capacity = var.instance_count

  vpc_zone_identifier = var.subnet_ids

  default_cooldown          = 180
  health_check_grace_period = 180
  health_check_type         = "EC2"

  termination_policies = [
    "OldestLaunchConfiguration",
  ]

  lifecycle {
    create_before_destroy = true
  }
}
