mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-east-1:123456789012:mock"
    }
  }

  mock_resource "aws_ec2_transit_gateway" {
    defaults = {
      arn = "arn:aws:ec2:us-east-1:123456789012:transit-gateway/tgw-00000000000000000"
    }
  }

  mock_resource "aws_networkfirewall_firewall_policy" {
    defaults = {
      arn = "arn:aws:network-firewall:us-east-1:123456789012:firewall-policy/mock"
    }
  }

  mock_resource "aws_networkfirewall_rule_group" {
    defaults = {
      arn = "arn:aws:network-firewall:us-east-1:123456789012:stateful-rulegroup/mock"
    }
  }

  mock_resource "aws_networkfirewall_firewall" {
    defaults = {
      arn = "arn:aws:network-firewall:us-east-1:123456789012:firewall/mock"
    }
  }

  mock_resource "aws_ram_resource_share" {
    defaults = {
      arn = "arn:aws:ram:us-east-1:123456789012:resource-share/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "random" {}

run "a_single_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zone_count = 1
  }

  expect_failures = [var.availability_zone_count]
}

run "two_spokes_sharing_a_range_are_rejected" {
  command = plan

  variables {
    spoke_vpcs = {
      workload = { cidr_block = "10.1.0.0/16" }
      shared   = { cidr_block = "10.1.0.0/16" }
    }
  }

  expect_failures = [var.spoke_vpcs]
}

run "forwarding_a_domain_without_name_servers_is_rejected" {
  command = plan

  variables {
    on_premises_domain = "corp.example."
  }

  expect_failures = [var.on_premises_dns_servers]
}

run "the_default_hub_attaches_every_spoke_and_serves_them_all_one_private_zone" {
  command = plan

  assert {
    condition     = length(module.spoke_networks) == 2
    error_message = "The default configuration should create one VPC per entry in spoke_vpcs."
  }

  assert {
    condition     = length(module.spoke_attachments) == length(module.spoke_networks)
    error_message = "Every spoke VPC should be attached to the transit gateway; a spoke without an attachment is an island."
  }

  assert {
    condition     = length(module.spoke_zone_associations) == length(module.spoke_networks)
    error_message = "Every spoke VPC should be associated with the private hosted zone, or names resolve in some spokes and not others."
  }

  assert {
    condition     = length(output.spoke_vpc_ids) == 2
    error_message = "The spoke_vpc_ids output should name every spoke the architecture created."
  }
}

run "adding_a_spoke_widens_the_attachments_and_the_zone_together" {
  command = plan

  variables {
    spoke_vpcs = {
      workload = { cidr_block = "10.1.0.0/16" }
      shared   = { cidr_block = "10.2.0.0/16" }
      data     = { cidr_block = "10.3.0.0/16" }
    }
  }

  assert {
    condition     = length(module.spoke_attachments) == 3
    error_message = "A third spoke should bring a third transit gateway attachment with it."
  }

  assert {
    condition     = length(module.spoke_zone_associations) == 3
    error_message = "A third spoke should also be associated with the private hosted zone."
  }
}

run "the_defaults_build_the_hub_alone_and_nothing_optional" {
  command = plan

  assert {
    condition     = length(module.customer_gateway) == 0 && length(module.vpn) == 0
    error_message = "A customer gateway and a VPN connection should only be created when an on-premises address is supplied."
  }

  assert {
    condition     = length(module.vpn_tunnel_alarm) == 0
    error_message = "There is nothing to alarm on when no VPN connection exists."
  }

  assert {
    condition     = output.vpn_connection_id == null && length(output.vpn_tunnel_addresses) == 0
    error_message = "Without a VPN connection the outputs describing it should be empty rather than an error."
  }

  assert {
    condition     = length(module.on_premises_forwarding) == 0
    error_message = "A forwarding rule should only be created when an on-premises domain is supplied."
  }

  assert {
    condition     = length(module.resource_share) == 0 && output.resource_share_arn == null
    error_message = "A resource share should only be created when there is a principal to share with."
  }

  assert {
    condition     = length(module.budget) == 0 && length(module.alerts.subscription_arns) == 0
    error_message = "Neither a budget nor a topic subscription should appear without an amount and an address to give them."
  }
}

run "an_on_premises_network_creates_the_vpn_its_alarm_and_the_forwarding_rule" {
  command = plan

  variables {
    on_premises_ip          = "198.51.100.10"
    on_premises_domain      = "corp.example."
    on_premises_dns_servers = ["192.168.10.53", "192.168.11.53"]
  }

  assert {
    condition     = length(module.customer_gateway) == 1 && length(module.vpn) == 1
    error_message = "Supplying an on-premises address should create a customer gateway and a site-to-site VPN connection onto the transit gateway."
  }

  assert {
    condition     = length(module.vpn_tunnel_alarm) == 1
    error_message = "A VPN connection should arrive with an alarm on its tunnel state."
  }

  assert {
    condition     = length(output.vpn_tunnel_addresses) == 2
    error_message = "AWS builds every site-to-site VPN connection with two tunnels, and both addresses are needed on-premises."
  }

  assert {
    condition     = length(module.on_premises_forwarding) == 1
    error_message = "Supplying an on-premises domain and its name servers should create a forwarding rule through the outbound endpoint."
  }
}

run "shared_principals_create_one_share_and_a_budget_notifies_the_alarm_topic" {
  command = plan

  variables {
    shared_principals = ["123456789012", "210987654321"]
    monthly_budget    = "400"
    alarm_email       = "network@example.com"
  }

  assert {
    condition     = length(module.resource_share) == 1
    error_message = "Every principal belongs to the single share for the transit gateway, not to a share of its own."
  }

  assert {
    condition     = length(module.budget) == 1
    error_message = "Supplying a monthly amount should create a budget."
  }

  assert {
    condition     = length(module.alerts.subscription_arns) == 1
    error_message = "Supplying an address should subscribe it to the alarm topic."
  }
}

run "a_single_apply_builds_the_hub_and_every_association" {
  command = apply

  variables {
    on_premises_ip          = "198.51.100.10"
    on_premises_domain      = "corp.example."
    on_premises_dns_servers = ["192.168.10.53"]
    shared_principals       = ["123456789012"]
  }

  assert {
    condition     = output.transit_gateway_id != null
    error_message = "The apply should create the transit gateway every association refers to."
  }

  assert {
    condition     = output.hub_route_table_id != null
    error_message = "The hub attachment should associate with its route table in the same apply that creates it."
  }

  assert {
    condition     = output.inspection_route_table_id != null
    error_message = "The spokes and the VPN should associate with the inspection route table in the same apply, which is what sends their traffic through the firewall."
  }

  assert {
    condition     = output.resource_share_arn != null
    error_message = "The transit gateway should take its place in the resource share in the same apply."
  }
}
