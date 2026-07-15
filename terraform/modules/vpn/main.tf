terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.dev]
    }
  }
}

data "aws_ami" "ubuntu" {
  provider    = aws.dev
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_eip" "strongswan" {
  provider = aws.dev
  domain   = "vpc"
  tags     = { Name = "${upper(var.name_prefix)}-STRONGSWAN-EIP" }
}

resource "aws_vpn_gateway" "this" {
  vpc_id          = var.prd_vpc_id
  amazon_side_asn = 64512
  tags            = { Name = "${upper(var.name_prefix)}-VGW" }
}

resource "aws_customer_gateway" "this" {
  bgp_asn     = 65000
  ip_address  = aws_eip.strongswan.public_ip
  type        = "ipsec.1"
  device_name = "StrongSwan on EC2"
  tags        = { Name = "${upper(var.name_prefix)}-CGW" }
}

resource "aws_cloudwatch_log_group" "vpn" {
  name              = "/aws/vpn/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${upper(var.name_prefix)}-TUNNEL-LOGS" }
}

resource "aws_vpn_connection" "this" {
  customer_gateway_id = aws_customer_gateway.this.id
  vpn_gateway_id      = aws_vpn_gateway.this.id
  type                = "ipsec.1"
  static_routes_only  = true

  local_ipv4_network_cidr  = var.dev_test_cidr
  remote_ipv4_network_cidr = var.prd_test_cidr
  preshared_key_storage    = "SecretsManager"

  tunnel1_inside_cidr = var.tunnel1_inside_cidr
  tunnel2_inside_cidr = var.tunnel2_inside_cidr

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel2_phase2_dh_group_numbers      = [14]
  tunnel1_dpd_timeout_action           = "restart"
  tunnel2_dpd_timeout_action           = "restart"
  tunnel1_startup_action               = "start"
  tunnel2_startup_action               = "start"

  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn.arn
      log_output_format = "json"
    }
  }

  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn.arn
      log_output_format = "json"
    }
  }

  tags = { Name = "${upper(var.name_prefix)}-S2S-VPN" }
}

locals {
  tunnels = {
    tunnel1 = {
      outside_ip    = aws_vpn_connection.this.tunnel1_address
      cgw_inside_ip = aws_vpn_connection.this.tunnel1_cgw_inside_address
      vgw_inside_ip = aws_vpn_connection.this.tunnel1_vgw_inside_address
      mark          = 100
      route_metric  = 100
    }
    tunnel2 = {
      outside_ip    = aws_vpn_connection.this.tunnel2_address
      cgw_inside_ip = aws_vpn_connection.this.tunnel2_cgw_inside_address
      vgw_inside_ip = aws_vpn_connection.this.tunnel2_vgw_inside_address
      mark          = 200
      route_metric  = 200
    }
  }

  protected_networks = {
    dev = var.dev_test_cidr
    prd = var.prd_test_cidr
  }
}

resource "aws_vpn_connection_route" "dev_test" {
  destination_cidr_block = var.dev_test_cidr
  vpn_connection_id      = aws_vpn_connection.this.id
}

resource "aws_security_group" "strongswan" {
  provider    = aws.dev
  name        = "${var.name_prefix}-strongswan-sg"
  description = "StrongSwan Site-to-Site VPN customer gateway"
  vpc_id      = var.dev_vpc_id
  tags        = { Name = "${upper(var.name_prefix)}-STRONGSWAN-SG" }
}

resource "aws_vpc_security_group_egress_rule" "strongswan_all" {
  provider          = aws.dev
  security_group_id = aws_security_group.strongswan.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "ike" {
  provider = aws.dev
  for_each = local.tunnels

  security_group_id = aws_security_group.strongswan.id
  cidr_ipv4         = "${each.value.outside_ip}/32"
  from_port         = 500
  to_port           = 500
  ip_protocol       = "udp"
  description       = "IKE from AWS ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "nat_t" {
  provider = aws.dev
  for_each = local.tunnels

  security_group_id = aws_security_group.strongswan.id
  cidr_ipv4         = "${each.value.outside_ip}/32"
  from_port         = 4500
  to_port           = 4500
  ip_protocol       = "udp"
  description       = "NAT-T from AWS ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "esp" {
  provider = aws.dev
  for_each = local.tunnels

  security_group_id = aws_security_group.strongswan.id
  cidr_ipv4         = "${each.value.outside_ip}/32"
  ip_protocol       = "50"
  description       = "ESP from AWS ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "protected_networks" {
  provider = aws.dev
  for_each = local.protected_networks

  security_group_id = aws_security_group.strongswan.id
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
  description       = "Forwarded VPN traffic for ${each.key} test network"
}

resource "aws_iam_role" "strongswan" {
  name               = "${var.name_prefix}-strongswan-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.strongswan.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_vpn_secret" {
  statement {
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_vpn_connection.this.preshared_key_arn]
  }
}

resource "aws_iam_role_policy" "read_vpn_secret" {
  name   = "read-managed-vpn-preshared-keys"
  role   = aws_iam_role.strongswan.id
  policy = data.aws_iam_policy_document.read_vpn_secret.json
}

data "aws_iam_policy_document" "ssm_session_logs" {
  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${var.session_log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "ssm_session_logs" {
  name   = "write-session-manager-logs"
  role   = aws_iam_role.strongswan.id
  policy = data.aws_iam_policy_document.ssm_session_logs.json
}

resource "aws_iam_instance_profile" "strongswan" {
  name = "${var.name_prefix}-strongswan-profile"
  role = aws_iam_role.strongswan.name
}

resource "aws_instance" "strongswan" {
  provider = aws.dev

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.strongswan_instance_type
  subnet_id                   = var.dev_public_subnet_id
  private_ip                  = var.strongswan_private_ip
  vpc_security_group_ids      = [aws_security_group.strongswan.id]
  iam_instance_profile        = aws_iam_instance_profile.strongswan.name
  associate_public_ip_address = true
  source_dest_check           = false
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/strongswan-user-data.sh.tftpl", {
    expected_public_ip = aws_eip.strongswan.public_ip
    prd_region         = var.prd_region
    prd_test_cidr      = var.prd_test_cidr
    dev_test_cidr      = var.dev_test_cidr
    vpn_secret_arn     = aws_vpn_connection.this.preshared_key_arn
    tunnel1            = local.tunnels.tunnel1
    tunnel2            = local.tunnels.tunnel2
    updown_script_b64  = base64encode(file("${path.module}/templates/aws-vti-updown.sh"))
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  depends_on = [
    aws_iam_role_policy.read_vpn_secret,
    aws_iam_role_policy.ssm_session_logs,
    aws_iam_role_policy_attachment.ssm,
  ]

  tags = { Name = "${upper(var.name_prefix)}-STRONGSWAN-CGW" }
}

resource "aws_eip_association" "strongswan" {
  provider      = aws.dev
  allocation_id = aws_eip.strongswan.id
  instance_id   = aws_instance.strongswan.id
}

resource "aws_route" "prd_test_to_dev" {
  route_table_id         = var.prd_vpn_route_table_id
  destination_cidr_block = var.dev_test_cidr
  gateway_id             = aws_vpn_gateway.this.id

  depends_on = [aws_vpn_connection_route.dev_test]
}

resource "aws_route" "dev_test_to_prd" {
  provider = aws.dev

  route_table_id         = var.dev_vpn_route_table_id
  destination_cidr_block = var.prd_test_cidr
  network_interface_id   = aws_instance.strongswan.primary_network_interface_id

  depends_on = [aws_eip_association.strongswan]
}

resource "aws_cloudwatch_metric_alarm" "tunnel_down" {
  for_each = local.tunnels

  alarm_name          = "${var.name_prefix}-${each.key}-down"
  alarm_description   = "AWS Site-to-Site VPN ${each.key} is down."
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  actions_enabled     = length(var.alarm_actions) > 0
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions

  dimensions = {
    VpnId           = aws_vpn_connection.this.id
    TunnelIpAddress = each.value.outside_ip
  }

  tags = { Name = "${upper(var.name_prefix)}-${upper(each.key)}-ALARM" }
}
