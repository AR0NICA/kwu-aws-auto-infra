variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "prd_cidr" { type = string }
variable "session_log_group_arn" { type = string }

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

locals {
  public_subnet_cidr   = "10.230.1.0/24"
  tomcat_subnet_cidr   = "10.230.2.0/24"
  database_subnet_cidr = "10.230.3.0/24"
  vpn_test_subnet_cidr = "172.31.240.0/24"
  availability_zone    = "us-east-1a"
}

data "aws_ami" "ubuntu" {
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

data "aws_partition" "current" {}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "session_logs" {
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

resource "aws_iam_role" "ssm_managed_node" {
  name               = "${var.name_prefix}-ssm-managed-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_managed_node" {
  role       = aws_iam_role.ssm_managed_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ssm_session_logs" {
  name   = "write-session-manager-logs"
  role   = aws_iam_role.ssm_managed_node.id
  policy = data.aws_iam_policy_document.session_logs.json
}

resource "aws_iam_instance_profile" "ssm_managed_node" {
  name = "${var.name_prefix}-ssm-managed-node-profile"
  role = aws_iam_role.ssm_managed_node.name
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "KWU-DEV-VPC" }
}

# Keep the default security group empty; named workload groups carry every
# required rule and AWS Config can verify this baseline continuously.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-DEV-VPC-DEFAULT-SG-CLOSED" }
}

resource "aws_vpc_ipv4_cidr_block_association" "vpn_test" {
  vpc_id     = aws_vpc.this.id
  cidr_block = local.vpn_test_subnet_cidr
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-DEV-VPC-IGW" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "KWU-DEV-VPC-NGINX-PUB-1A" }
}

resource "aws_subnet" "tomcat" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.tomcat_subnet_cidr
  availability_zone = local.availability_zone
  tags              = { Name = "KWU-DEV-VPC-TOMCAT-PRI-1A" }
}

resource "aws_subnet" "database" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.database_subnet_cidr
  availability_zone = local.availability_zone
  tags              = { Name = "KWU-DEV-VPC-DB-PRI-1A" }
}

resource "aws_subnet" "vpn_test" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.vpn_test_subnet_cidr
  availability_zone = local.availability_zone
  tags              = { Name = "KWU-DEV-VPC-VPN-TEST-PRI-1A" }

  depends_on = [aws_vpc_ipv4_cidr_block_association.vpn_test]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-DEV-VPC-RT-PUB" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "KWU-DEV-VPC-NGW-EIP-1A" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.this]
  tags          = { Name = "KWU-DEV-VPC-NGW-1A" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-DEV-VPC-RT-PRI" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "tomcat" {
  subnet_id      = aws_subnet.tomcat.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "database" {
  subnet_id      = aws_subnet.database.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "vpn_test" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "KWU-DEV-VPC-RT-VPN-TEST" }
}

resource "aws_route" "vpn_test_default" {
  route_table_id         = aws_route_table.vpn_test.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "vpn_test" {
  subnet_id      = aws_subnet.vpn_test.id
  route_table_id = aws_route_table.vpn_test.id
}

resource "aws_security_group" "nginx" {
  name        = "${var.name_prefix}-nginx-pub-sg-1a"
  description = "DEV public Nginx security group"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "KWU-DEV-VPC-NGINX-PUB-SG-1A" }
}

resource "aws_security_group" "tomcat" {
  name        = "${var.name_prefix}-tomcat-pri-sg-1a"
  description = "DEV private Tomcat security group"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "KWU-DEV-VPC-TOMCAT-PRI-SG-1A" }
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-db-pri-sg-1a"
  description = "DEV private database security group"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "KWU-DEV-VPC-DB-PRI-SG-1A" }
}

resource "aws_security_group" "vpn_test" {
  name        = "${var.name_prefix}-vpn-test-pri-sg-1a"
  description = "DEV private VPN packet-test security group"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "KWU-DEV-VPC-VPN-TEST-PRI-SG-1A" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    nginx    = aws_security_group.nginx.id
    tomcat   = aws_security_group.tomcat.id
    database = aws_security_group.database.id
    vpn_test = aws_security_group.vpn_test.id
  }

  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "vpn_test_icmp" {
  security_group_id = aws_security_group.vpn_test.id
  cidr_ipv4         = var.prd_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "ICMP from PRD through the encrypted VPN"
}

resource "aws_vpc_security_group_ingress_rule" "nginx_public_http" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.nginx.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  ip_protocol       = "tcp"
  description       = "Lab web access"
}

resource "aws_vpc_security_group_ingress_rule" "peer_icmp" {
  for_each = {
    nginx    = aws_security_group.nginx.id
    tomcat   = aws_security_group.tomcat.id
    database = aws_security_group.database.id
  }

  security_group_id = each.value
  cidr_ipv4         = var.prd_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "ICMP from PRD VPC over peering"
}

resource "aws_vpc_security_group_ingress_rule" "tomcat_from_dev_nginx" {
  security_group_id            = aws_security_group.tomcat.id
  referenced_security_group_id = aws_security_group.nginx.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Tomcat from DEV Nginx"
}

resource "aws_vpc_security_group_ingress_rule" "database_mysql_from_dev" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.tomcat.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL from DEV Tomcat"
}

resource "aws_instance" "nginx" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  private_ip                  = "10.230.1.240"
  vpc_security_group_ids      = [aws_security_group.nginx.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ssm_managed_node.name
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || snap start amazon-ssm-agent
    apt-get update
    apt-get install -y nginx
    cat > /var/www/html/index.html <<'HTML'
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KWU DEV Nginx</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b1220;color:#f8fafc;font-family:Inter,system-ui,sans-serif}.card{padding:36px;border:1px solid #38bdf855;border-radius:18px;background:#0f172acc;box-shadow:0 24px 60px #0008}.badge{color:#38bdf8;font:700 12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase}h1{margin:14px 0 8px;font-size:34px}.ip{color:#7dd3fc;font-family:ui-monospace,monospace}</style></head><body><main class="card"><div class="badge">us-east-1 / peering lab</div><h1>KWU DEV Nginx</h1><p>Public edge node for the peered DEV VPC.</p><p class="ip">10.230.1.240</p></main></body></html>
    HTML
    systemctl enable nginx
    systemctl restart nginx
  USERDATA

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  depends_on = [
    aws_iam_role_policy.ssm_session_logs,
    aws_iam_role_policy_attachment.ssm_managed_node,
  ]
  tags = { Name = "KWU-DEV-VPC-NGINX-PUB-1A" }
}

resource "aws_instance" "tomcat" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.tomcat.id
  private_ip                  = "10.230.2.240"
  vpc_security_group_ids      = [aws_security_group.tomcat.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ssm_managed_node.name
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || snap start amazon-ssm-agent
    apt-get update
    apt-get install -y openjdk-17-jdk tomcat9
    systemctl enable tomcat9
    systemctl restart tomcat9
  USERDATA

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  depends_on = [
    aws_iam_role_policy.ssm_session_logs,
    aws_iam_role_policy_attachment.ssm_managed_node,
  ]
  tags = { Name = "KWU-DEV-VPC-TOMCAT-PRI-1A" }
}

resource "aws_instance" "database" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.database.id
  private_ip                  = "10.230.3.240"
  vpc_security_group_ids      = [aws_security_group.database.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ssm_managed_node.name
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || snap start amazon-ssm-agent
    apt-get update
    apt-get install -y mariadb-server
    systemctl enable mariadb
    systemctl restart mariadb
  USERDATA

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  depends_on = [
    aws_iam_role_policy.ssm_session_logs,
    aws_iam_role_policy_attachment.ssm_managed_node,
  ]
  tags = { Name = "KWU-DEV-VPC-DB-PRI-1A" }
}

resource "aws_instance" "vpn_test" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.vpn_test.id
  private_ip                  = "172.31.240.10"
  vpc_security_group_ids      = [aws_security_group.vpn_test.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ssm_managed_node.name
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -Eeuo pipefail
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || snap start amazon-ssm-agent
  USERDATA

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  depends_on = [
    aws_iam_role_policy.ssm_session_logs,
    aws_iam_role_policy_attachment.ssm_managed_node,
  ]
  tags = { Name = "KWU-DEV-VPC-VPN-TEST-PRI-1A" }
}

output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = var.vpc_cidr }
output "public_route_table_id" { value = aws_route_table.public.id }
output "private_route_table_id" { value = aws_route_table.private.id }
output "route_table_ids" {
  value = {
    public   = aws_route_table.public.id
    private  = aws_route_table.private.id
    vpn_test = aws_route_table.vpn_test.id
  }
}
output "endpoint_subnet_ids" { value = { private = aws_subnet.tomcat.id } }
output "managed_instance_security_group_ids" {
  value = {
    nginx    = aws_security_group.nginx.id
    tomcat   = aws_security_group.tomcat.id
    database = aws_security_group.database.id
    vpn_test = aws_security_group.vpn_test.id
  }
}
output "nginx_public_ip" { value = aws_instance.nginx.public_ip }
output "instance_ids" {
  value = {
    nginx    = aws_instance.nginx.id
    tomcat   = aws_instance.tomcat.id
    database = aws_instance.database.id
    vpn_test = aws_instance.vpn_test.id
  }
}
output "private_ips" {
  value = {
    nginx    = aws_instance.nginx.private_ip
    tomcat   = aws_instance.tomcat.private_ip
    db       = aws_instance.database.private_ip
    vpn_test = aws_instance.vpn_test.private_ip
  }
}
output "public_subnet_id" { value = aws_subnet.public.id }
output "vpn_test_route_table_id" { value = aws_route_table.vpn_test.id }
output "vpn_test_instance_id" { value = aws_instance.vpn_test.id }
output "vpn_test_private_ip" { value = aws_instance.vpn_test.private_ip }
