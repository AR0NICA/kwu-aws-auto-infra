resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids

  tags = { Name = "${upper(var.name_prefix)}-ALB" }
}

resource "aws_lb_target_group" "nginx" {
  name        = "${var.name_prefix}-nginx-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled = true
    path    = "/"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "nginx" {
  for_each = var.nginx_instances

  target_group_arn = aws_lb_target_group.nginx.arn
  target_id        = each.value.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}
