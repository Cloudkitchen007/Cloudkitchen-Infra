# =============================================================================
# CLOUDKITCHEN – WAF (Web Application Firewall)
#
# Attached to the CloudFront distribution to block common web attacks.
# Must be created in us-east-1 — AWS requires all CloudFront-scoped WAF
# WebACLs to live in N. Virginia regardless of the app's region.
# =============================================================================

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "${local.env_prefix}-waf"
  description = "WAF protecting CloudKitchen CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.env_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.global_tags
}
