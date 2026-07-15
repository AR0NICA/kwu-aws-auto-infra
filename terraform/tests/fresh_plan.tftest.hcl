mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "ap-northeast-2"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_acm_certificate" {
    override_during = plan

    defaults = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        {
          domain_name           = "example.com"
          resource_record_name  = "_test.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "_validation.acm-validations.aws"
        },
        {
          domain_name           = "*.example.com"
          resource_record_name  = "_wildcard.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "_wildcard.acm-validations.aws"
        },
      ]
    }
  }
}

mock_provider "aws" {
  alias = "use1"

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "fresh_deployment_plan" {
  command = plan

  variables {
    aws_region     = "ap-northeast-2"
    dev_region     = "us-east-1"
    domain_name    = "example.com"
    waf_count_mode = false
  }

  assert {
    condition     = output.website_url == "https://example.com"
    error_message = "The apex website output must be derived from domain_name."
  }

  assert {
    condition     = output.vpn_test_ip == "172.31.240.10"
    error_message = "The dedicated VPN test address must remain outside the PCX CIDR."
  }
}
