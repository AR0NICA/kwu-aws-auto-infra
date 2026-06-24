variable "name_prefix" { type = string }
variable "database_name" { type = string }
variable "master_username" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = { Name = "KWU-PRD-VPC-DB-SUBNETS" }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-mysql"

  engine                      = "mysql"
  instance_class              = "db.t3.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = var.database_name
  username                    = var.master_username
  manage_master_user_password = true
  port                        = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
  tags                    = { Name = "KWU-PRD-VPC-MYSQL" }
}

output "endpoint" { value = aws_db_instance.this.address }
output "master_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
