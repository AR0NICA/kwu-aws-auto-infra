provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

provider "aws" {
  alias  = "use1"
  region = var.dev_region

  default_tags {
    tags = local.common_tags
  }
}
