data "aws_route53_zone" "public" {
  name         = "${var.domain_name}."
  private_zone = false
}

resource "aws_route53_record" "website" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_hosted_zone_id
    evaluate_target_health = false
  }
}
