module "key" {
  source  = "kn47ytv9mv/kms-key/aws"
  version = "~> 1.0"

  description = "${var.name} hybrid network log encryption key"

  tags = var.tags
}

module "key_alias" {
  source  = "kn47ytv9mv/kms-alias/aws"
  version = "~> 1.0"

  name          = var.name
  target_key_id = module.key.arn
}

module "flow_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/vpc/${var.name}"
  kms_key_id        = module.key.arn
  retention_in_days = var.log_retention_days

  tags = var.tags
}

module "firewall_log_group" {
  source  = "kn47ytv9mv/cloudwatch-log-group/aws"
  version = "~> 1.0"

  name              = "/aws/network-firewall/${var.name}"
  kms_key_id        = module.key.arn
  retention_in_days = var.log_retention_days

  tags = var.tags
}

module "log_bucket" {
  source  = "kn47ytv9mv/s3/aws"
  version = "~> 1.0"

  bucket            = "${var.name}-network-logs"
  kms_master_key_id = module.key.arn

  tags = var.tags
}

module "transit_gateway" {
  source  = "kn47ytv9mv/transit-gateway/aws"
  version = "~> 1.0"

  description     = "${var.name} hybrid network hub"
  amazon_side_asn = var.amazon_side_asn

  default_route_table_association = true
  default_route_table_propagation = true

  dns_support      = true
  vpn_ecmp_support = true

  tags = var.tags
}

module "hub_network" {
  source  = "kn47ytv9mv/vpc/aws"
  version = "~> 1.0"

  vpc_cidr                = var.hub_vpc_cidr
  availability_zone_count = var.availability_zone_count

  subnets = {
    attachment = {}

    inspection = {
      custom_routes = [
        { cidr_block = "0.0.0.0/0", transit_gateway_id = module.transit_gateway.id },
      ]
    }

    resolver = {
      custom_routes = [
        { cidr_block = var.on_premises_cidr, transit_gateway_id = module.transit_gateway.id },
      ]
    }
  }

  flow_logs = [
    {
      destination_arn  = module.flow_log_group.arn
      destination_type = "cloud-watch-logs"
    },
  ]

  tags = var.tags
}

module "spoke_networks" {
  source   = "kn47ytv9mv/vpc/aws"
  version  = "~> 1.0"
  for_each = var.spoke_vpcs

  vpc_cidr                = each.value.cidr_block
  availability_zone_count = var.availability_zone_count

  subnets = {
    attachment = {}

    workload = {
      custom_routes = [
        { cidr_block = "0.0.0.0/0", transit_gateway_id = module.transit_gateway.id },
      ]
    }
  }

  flow_logs = [
    {
      destination_arn  = module.flow_log_group.arn
      destination_type = "cloud-watch-logs"
    },
  ]

  tags = var.tags
}

module "hub_attachment" {
  source  = "kn47ytv9mv/transit-gateway-vpc-attachment/aws"
  version = "~> 1.0"

  transit_gateway_id = module.transit_gateway.id
  vpc_id             = module.hub_network.vpc_id
  subnet_ids         = module.hub_network.subnet_ids["attachment"]

  appliance_mode_support = true
  dns_support            = true

  tags = var.tags
}

module "spoke_attachments" {
  source   = "kn47ytv9mv/transit-gateway-vpc-attachment/aws"
  version  = "~> 1.0"
  for_each = var.spoke_vpcs

  transit_gateway_id = module.transit_gateway.id
  vpc_id             = module.spoke_networks[each.key].vpc_id
  subnet_ids         = module.spoke_networks[each.key].subnet_ids["attachment"]

  dns_support = true

  tags = var.tags
}

module "hub_route_table" {
  source  = "kn47ytv9mv/transit-gateway-route-table/aws"
  version = "~> 1.0"

  transit_gateway_id           = module.transit_gateway.id
  replace_existing_association = true

  associations = [module.hub_attachment.id]

  propagations = concat(
    [for attachment in module.spoke_attachments : attachment.id],
    var.on_premises_ip != null ? [module.vpn[0].transit_gateway_attachment_id] : [],
  )

  tags = var.tags
}

module "inspection_route_table" {
  source  = "kn47ytv9mv/transit-gateway-route-table/aws"
  version = "~> 1.0"

  transit_gateway_id           = module.transit_gateway.id
  replace_existing_association = true

  associations = concat(
    [for attachment in module.spoke_attachments : attachment.id],
    var.on_premises_ip != null ? [module.vpn[0].transit_gateway_attachment_id] : [],
  )

  routes = [
    {
      destination_cidr_block        = "0.0.0.0/0"
      transit_gateway_attachment_id = module.hub_attachment.id
    },
  ]

  tags = var.tags
}

module "customer_gateway" {
  source  = "kn47ytv9mv/customer-gateway/aws"
  version = "~> 1.0"
  count   = var.on_premises_ip != null ? 1 : 0

  bgp_asn     = var.on_premises_asn
  ip_address  = var.on_premises_ip
  device_name = "${var.name}-on-premises"

  tags = var.tags
}

module "vpn" {
  source  = "kn47ytv9mv/vpn-connection/aws"
  version = "~> 1.0"
  count   = var.on_premises_ip != null ? 1 : 0

  customer_gateway_id = module.customer_gateway[0].id
  transit_gateway_id  = module.transit_gateway.id

  remote_ipv4_network_cidr = var.on_premises_cidr

  tunnel1_options = {
    dpd_timeout_action = "restart"
    startup_action     = "start"
  }

  tunnel2_options = {
    dpd_timeout_action = "restart"
    startup_action     = "start"
  }

  tags = var.tags
}

module "resolver_security_group" {
  source  = "kn47ytv9mv/vpc-security-groups/aws"
  version = "~> 1.0"

  name        = "${var.name}-resolver"
  vpc_id      = module.hub_network.vpc_id
  description = "Route 53 Resolver endpoints for ${var.name}, reachable only from the networks this hub joins."

  ingress_rules = concat(
    [
      { description = "DNS over UDP from the hub", ip_protocol = "udp", from_port = 53, to_port = 53, cidr_ipv4 = var.hub_vpc_cidr },
      { description = "DNS over TCP from the hub", ip_protocol = "tcp", from_port = 53, to_port = 53, cidr_ipv4 = var.hub_vpc_cidr },
      { description = "DNS over UDP from the on-premises network", ip_protocol = "udp", from_port = 53, to_port = 53, cidr_ipv4 = var.on_premises_cidr },
      { description = "DNS over TCP from the on-premises network", ip_protocol = "tcp", from_port = 53, to_port = 53, cidr_ipv4 = var.on_premises_cidr },
    ],
    [for spoke_key, spoke in var.spoke_vpcs : { description = "DNS over UDP from the ${spoke_key} spoke", ip_protocol = "udp", from_port = 53, to_port = 53, cidr_ipv4 = spoke.cidr_block }],
    [for spoke_key, spoke in var.spoke_vpcs : { description = "DNS over TCP from the ${spoke_key} spoke", ip_protocol = "tcp", from_port = 53, to_port = 53, cidr_ipv4 = spoke.cidr_block }],
  )

  egress_rules = [
    { description = "DNS over UDP to the on-premises name servers", ip_protocol = "udp", from_port = 53, to_port = 53, cidr_ipv4 = var.on_premises_cidr },
    { description = "DNS over TCP to the on-premises name servers", ip_protocol = "tcp", from_port = 53, to_port = 53, cidr_ipv4 = var.on_premises_cidr },
  ]

  tags = var.tags
}

module "inbound_resolver" {
  source  = "kn47ytv9mv/route53-resolver-endpoint/aws"
  version = "~> 1.0"

  direction          = "INBOUND"
  security_group_ids = [module.resolver_security_group.id]

  ip_addresses = [
    for subnet_id in module.hub_network.subnet_ids["resolver"] : { subnet_id = subnet_id }
  ]

  tags = var.tags
}

module "outbound_resolver" {
  source  = "kn47ytv9mv/route53-resolver-endpoint/aws"
  version = "~> 1.0"

  direction          = "OUTBOUND"
  security_group_ids = [module.resolver_security_group.id]

  ip_addresses = [
    for subnet_id in module.hub_network.subnet_ids["resolver"] : { subnet_id = subnet_id }
  ]

  tags = var.tags
}

module "on_premises_forwarding" {
  source  = "kn47ytv9mv/route53-resolver-rule/aws"
  version = "~> 1.0"
  count   = var.on_premises_domain != null ? 1 : 0

  domain_name          = var.on_premises_domain
  rule_type            = "FORWARD"
  resolver_endpoint_id = module.outbound_resolver.id

  target_ips = [for address in var.on_premises_dns_servers : { ip = address }]

  vpc_ids = concat(
    [module.hub_network.vpc_id],
    [for network in module.spoke_networks : network.vpc_id],
  )

  tags = var.tags
}

module "internal_zone" {
  source  = "kn47ytv9mv/route53-zone/aws"
  version = "~> 1.0"

  name    = var.internal_domain
  comment = "Private zone for ${var.name}, answered inside every attached VPC and, through the inbound endpoint, from on-premises."
  vpc_id  = module.hub_network.vpc_id

  tags = var.tags
}

module "spoke_zone_associations" {
  source   = "kn47ytv9mv/route53-zone-association/aws"
  version  = "~> 1.0"
  for_each = var.spoke_vpcs

  zone_id = module.internal_zone.id
  vpc_id  = module.spoke_networks[each.key].vpc_id
}

module "firewall_rule_group" {
  source  = "kn47ytv9mv/network-firewall-rule-group/aws"
  version = "~> 1.0"

  name        = "${var.name}-baseline"
  description = "Baseline stateful rules for ${var.name}: what must never cross the hub, and a record of everything that leaves it."
  type        = "STATEFUL"
  capacity    = 100

  ip_sets = {
    HOME_NET = concat(
      [var.hub_vpc_cidr, var.on_premises_cidr],
      [for spoke in var.spoke_vpcs : spoke.cidr_block],
    )
  }

  rules_string = <<-EOT
    drop tcp $HOME_NET any -> $EXTERNAL_NET 23 (msg:"Telnet leaving the hybrid network"; sid:1000001; rev:1;)
    drop tcp $EXTERNAL_NET any -> $HOME_NET 3389 (msg:"Remote desktop entering the hybrid network"; sid:1000002; rev:1;)
    alert tcp $HOME_NET any -> $EXTERNAL_NET any (flow:established; msg:"Connection leaving the hybrid network"; sid:1000003; rev:1;)
  EOT

  tags = var.tags
}

module "firewall_policy" {
  source  = "kn47ytv9mv/network-firewall-policy/aws"
  version = "~> 1.0"

  name        = "${var.name}-inspection"
  description = "Hands every packet to the stateful engine for ${var.name}, rather than deciding anything on a single packet's headers."

  stateless_default_actions          = ["aws:forward_to_sfe"]
  stateless_fragment_default_actions = ["aws:forward_to_sfe"]

  stateful_rule_group_arns = [
    { resource_arn = module.firewall_rule_group.arn },
  ]

  tags = var.tags
}

module "firewall" {
  source  = "kn47ytv9mv/network-firewall/aws"
  version = "~> 1.0"

  name                = "${var.name}-inspection"
  description         = "Central inspection point for traffic crossing the ${var.name} hub."
  firewall_policy_arn = module.firewall_policy.arn
  vpc_id              = module.hub_network.vpc_id

  subnet_mapping = [
    for subnet_id in module.hub_network.subnet_ids["inspection"] : { subnet_id = subnet_id }
  ]

  logging_destinations = [
    {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = module.firewall_log_group.name }
    },
    {
      log_type             = "FLOW"
      log_destination_type = "S3"
      log_destination      = { bucketName = module.log_bucket.bucket, prefix = "firewall" }
    },
  ]

  tags = var.tags
}

module "resource_share" {
  source  = "kn47ytv9mv/ram-resource-share/aws"
  version = "~> 1.0"
  count   = length(var.shared_principals) > 0 ? 1 : 0

  name          = "${var.name}-transit-gateway"
  principals    = var.shared_principals
  resource_arns = [module.transit_gateway.arn]

  tags = var.tags
}

module "alerts" {
  source  = "kn47ytv9mv/sns-topic/aws"
  version = "~> 1.0"

  name         = "${var.name}-alerts"
  display_name = "${var.name} alerts"

  subscriptions = var.alarm_email != null ? [
    { protocol = "email", endpoint = var.alarm_email },
  ] : []

  tags = var.tags
}

module "vpn_tunnel_alarm" {
  source  = "kn47ytv9mv/cloudwatch-metric-alarm/aws"
  version = "~> 1.0"
  count   = var.on_premises_ip != null ? 1 : 0

  alarm_name        = "${var.name}-vpn-tunnel-down"
  alarm_description = "At least one of the two tunnels on the ${var.name} site-to-site VPN is down. Traffic still crosses on the surviving tunnel, which is precisely why this needs attention before the second one follows it."

  namespace   = "AWS/VPN"
  metric_name = "TunnelState"
  dimensions  = { VpnId = module.vpn[0].id }

  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  tags = var.tags
}

module "inbound_dns_alarm" {
  source  = "kn47ytv9mv/cloudwatch-metric-alarm/aws"
  version = "~> 1.0"

  alarm_name        = "${var.name}-inbound-dns-silent"
  alarm_description = "The inbound resolver endpoint for ${var.name} answered no queries over two consecutive periods. On-premises resolvers that stop asking have normally lost the path to the endpoint, not the need for it."

  namespace   = "AWS/Route53Resolver"
  metric_name = "InboundQueryVolume"
  dimensions  = { EndpointId = module.inbound_resolver.id }

  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  alarm_actions = [module.alerts.arn]
  ok_actions    = [module.alerts.arn]

  tags = var.tags
}

module "budget" {
  source  = "kn47ytv9mv/budget/aws"
  version = "~> 1.0"
  count   = var.monthly_budget != null ? 1 : 0

  name         = "${var.name}-monthly"
  limit_amount = var.monthly_budget

  notifications = [
    {
      threshold                 = 80
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [module.alerts.arn]
    },
  ]

  tags = var.tags
}

output "transit_gateway_id" {
  description = "The ID of the transit gateway every network in this architecture attaches to."
  value       = module.transit_gateway.id
}

output "transit_gateway_arn" {
  description = "ARN of the transit gateway, which is what a resource share grants another account access to."
  value       = module.transit_gateway.arn
}

output "hub_vpc_id" {
  description = "The ID of the hub VPC holding the firewall and the resolver endpoints."
  value       = module.hub_network.vpc_id
}

output "spoke_vpc_ids" {
  description = "Map of spoke name to the ID of the VPC created for it."
  value       = { for spoke_key, network in module.spoke_networks : spoke_key => network.vpc_id }
}

output "hub_route_table_id" {
  description = "The transit gateway route table the hub attachment is associated with once the associations are complete. Every other attachment propagates into it, so the firewall's return traffic finds its destination."
  value       = module.hub_route_table.id
}

output "inspection_route_table_id" {
  description = "The transit gateway route table whose only route sends every destination to the hub for inspection. Associating attachments with it is the step that turns the flat hub into an inspected one."
  value       = module.inspection_route_table.id
}

output "firewall_endpoint_ids" {
  description = "IDs of the firewall's endpoints, one per availability zone. These are the targets for the routes that send the hub's attachment subnets through the firewall, and they are only known once the firewall exists."
  value       = try([for state in module.firewall.firewall_status[0].sync_states : state.attachment[0].endpoint_id], [])
}

output "inbound_resolver_endpoint_id" {
  description = "The ID of the inbound resolver endpoint, to point on-premises conditional forwarders at."
  value       = module.inbound_resolver.id
}

output "outbound_resolver_endpoint_id" {
  description = "The ID of the outbound resolver endpoint every forwarding rule sends queries through."
  value       = module.outbound_resolver.id
}

output "internal_zone_id" {
  description = "The ID of the private hosted zone every attached VPC resolves against."
  value       = module.internal_zone.id
}

output "vpn_connection_id" {
  description = "The ID of the site-to-site VPN connection. Null when no on_premises_ip was supplied."
  value       = var.on_premises_ip != null ? module.vpn[0].id : null
}

output "vpn_tunnel_addresses" {
  description = "Public addresses of the two VPN tunnels, to configure on the on-premises device. Empty when no on_premises_ip was supplied."
  value       = var.on_premises_ip != null ? [module.vpn[0].tunnel1_address, module.vpn[0].tunnel2_address] : []
}

output "resource_share_arn" {
  description = "ARN of the resource share granting other accounts access to the transit gateway. Null when no shared_principals were supplied."
  value       = length(var.shared_principals) > 0 ? module.resource_share[0].arn : null
}

output "alerts_topic_arn" {
  description = "ARN of the topic every alarm in this architecture notifies."
  value       = module.alerts.arn
}
