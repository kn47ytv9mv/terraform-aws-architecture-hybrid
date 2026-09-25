variable "region" {
  default     = "us-east-1"
  description = "Region every resource in this architecture is created in."
}

variable "name" {
  default     = "hybrid"
  description = "Name prefix applied to every resource, so one account can hold several copies of this architecture without collision."
}

variable "hub_vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "IPv4 range for the hub VPC. The hub holds only network infrastructure — transit gateway, firewall, and resolver network interfaces — so it consumes very little of this range, and the spare room is deliberate: appliances added to the hub later are the hardest thing to renumber."
}

variable "spoke_vpcs" {
  default = {
    workload = { cidr_block = "10.1.0.0/16" }
    shared   = { cidr_block = "10.2.0.0/16" }
  }
  description = "Spoke VPCs to create and attach to the transit gateway, keyed by a short name that appears in the name of everything the spoke owns. Each entry needs a cidr_block. The ranges must not overlap one another, the hub, or the on-premises network: a transit gateway routes on destination CIDR alone and cannot tell two identical ranges apart."

  validation {
    condition     = length(var.spoke_vpcs) == length(distinct([for spoke in var.spoke_vpcs : spoke.cidr_block]))
    error_message = "Every spoke's cidr_block must be unique. Two spokes sharing a range attach successfully and then route unpredictably, which is far harder to diagnose than a refused apply."
  }
}

variable "availability_zone_count" {
  default     = 2
  description = "Availability zones the hub and every spoke spread across. Two is the minimum this architecture accepts."

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "This architecture needs at least two availability zones: AWS places a Route 53 Resolver endpoint's network interfaces in two separate zones and refuses to create one with fewer, and a firewall deployed into a single zone stops inspecting the moment that zone does."
  }
}

variable "amazon_side_asn" {
  default     = 64512
  description = "Private ASN the transit gateway presents on its side of every BGP session. It must differ from on_premises_asn, because a BGP session between two devices claiming the same ASN never establishes."
}

variable "on_premises_ip" {
  default     = null
  description = "Public IP address of the on-premises VPN device. Setting it creates a customer gateway, a site-to-site VPN connection onto the transit gateway, and an alarm on the tunnels. If null, the hub is built without a link to on-premises, which is a reasonable first apply — the VPN can be added afterwards without disturbing anything else."
}

variable "on_premises_asn" {
  default     = 65000
  description = "BGP ASN of the on-premises VPN device. Only used when on_premises_ip is set."
}

variable "on_premises_cidr" {
  default     = "192.168.0.0/16"
  description = "IPv4 range on the on-premises side of the VPN. The hub's resolver subnets route this range over the transit gateway so outbound DNS queries reach the on-premises name servers, and the firewall counts it as part of the internal network rather than the internet."
}

variable "on_premises_domain" {
  default     = null
  description = "DNS domain the on-premises name servers are authoritative for, as a fully qualified name ending in a dot. Setting it creates a forwarding rule, so queries for that domain from any attached VPC leave through the outbound resolver endpoint instead of being answered — wrongly — by the VPC resolver. If null, no forwarding rule is created and resolution towards on-premises does not work."
}

variable "on_premises_dns_servers" {
  default     = []
  description = "IPv4 addresses of the on-premises name servers the forwarding rule sends queries to. Required when on_premises_domain is set."

  validation {
    condition     = var.on_premises_domain == null || length(var.on_premises_dns_servers) > 0
    error_message = "Setting on_premises_domain requires at least one address in on_premises_dns_servers. A forwarding rule with no targets still matches the domain and then has nowhere to send the query, which resolves worse than not forwarding at all."
  }
}

variable "internal_domain" {
  default     = "hybrid.internal"
  description = "Domain of the private hosted zone the hub serves. Every VPC in the architecture is associated with it, so a name registered from one spoke resolves from the others and, through the inbound endpoint, from on-premises."
}


variable "shared_principals" {
  default     = []
  description = "AWS account IDs, an AWS Organizations organization ARN, or organizational unit ARNs allowed to attach their own VPCs to the transit gateway. If empty, no resource share is created and the transit gateway stays private to this account."
}

variable "log_retention_days" {
  default     = 90
  description = "Days flow logs and firewall alerts are kept in CloudWatch Logs. Network logs are the evidence for an investigation that usually begins weeks after the traffic itself, so shortening this saves very little and costs exactly the records an investigation needs."
}

variable "alarm_email" {
  default     = null
  description = "Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then."
}

variable "monthly_budget" {
  default     = null
  description = "Monthly spend in USD to alarm on, as a string. If null, no budget is created."
}

variable "tags" {
  default     = null
  description = "A map of tags applied to every resource in the architecture."
}
