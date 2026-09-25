# terraform-aws-architecture-hybrid

Terraform module for a hybrid network hub — a transit gateway joining
several VPCs and an on-premises network, with DNS resolving in both
directions and a firewall inspecting what crosses — assembled from this
family's single-purpose modules.

## Cost

This is the most expensive kind of module in this family, because it
stands up running infrastructure rather than configuration, and network
infrastructure bills by the hour whether anything uses it or not. At the
defaults the standing charges are an AWS Network Firewall with one
endpoint per availability zone, four Route 53 Resolver endpoint network
interfaces, three transit gateway attachments, two CloudWatch alarms,
and the storage behind flow logs and firewall logs. Supplying
`on_premises_ip` adds a site-to-site VPN connection. On top of the hourly
charges, every gigabyte that crosses the transit gateway is billed for
processing, and every gigabyte the firewall inspects is billed again.

The firewall is by a wide margin the largest line, and it scales with
`availability_zone_count` because AWS places one endpoint per zone.
Nothing here is free-tier. Destroy it when you are finished with it, and
set `monthly_budget` so a forecast overrun reaches you.

Deliberately absent: there are no NAT gateways. A network hub that also
performs central internet egress is a reasonable thing to build, and it
is not this. Every subnet here exists to hold a network interface.

## Design

Every resource comes from a published module in this family, resolved
from the Terraform Registry under a `~> 1.0` version constraint. This
module contains no `resource` blocks of its own; it is wiring and
nothing else. Read any individual module's README to
understand what it creates and why its defaults are what they are.

### What it builds

| Layer | Contents |
|---|---|
| Hub VPC | Three subnet tiers across `availability_zone_count` zones — `attachment` for the transit gateway's interfaces, `inspection` for the firewall's, `resolver` for the resolver endpoints' — plus flow logs to CloudWatch |
| Spoke VPCs | One VPC per entry in `spoke_vpcs`, each with an `attachment` tier and a `workload` tier whose default route leaves over the transit gateway, plus flow logs to the same log group |
| Transit gateway | The gateway itself, a VPC attachment per VPC, a hub route table, and an inspection route table whose only route sends every destination to the hub |
| On-premises | Customer gateway and a two-tunnel site-to-site VPN onto the transit gateway, created only when `on_premises_ip` is set |
| DNS | Private hosted zone associated with every VPC, an inbound and an outbound resolver endpoint in the hub, a security group admitting port 53 from the joined networks only, and a forwarding rule for the on-premises domain |
| Inspection | Stateful Suricata rule group, a firewall policy handing every packet to the stateful engine, and a firewall with one endpoint per zone, logging alerts to CloudWatch and flows to S3 |
| Sharing | Resource Access Manager share exposing the transit gateway to other accounts, created only when `shared_principals` is non-empty |
| Cross-cutting | Customer managed KMS key, S3 log bucket, SNS alarm topic, two CloudWatch alarms, optional budget |

DNS resolves in both directions because two separate mechanisms point at
each other. Outwards, the forwarding rule sends queries for
`on_premises_domain` through the outbound endpoint to the addresses in
`on_premises_dns_servers`, instead of letting the VPC resolver answer
`NXDOMAIN` for names it has never heard of. Inwards, the private hosted
zone is associated with every VPC and the inbound endpoint gives
on-premises resolvers somewhere to send a conditional forwarder. Neither
half is any use without the other, which is why both are built together.

### One apply, not two

Three pieces of this architecture are associations keyed on identifiers
AWS only issues at apply time: a transit gateway route table association
on an attachment ID, a resolver rule association on a VPC ID, and a
resource share association on the shared resource's ARN. Terraform
refuses to plan a set of instances whose keys it cannot enumerate, and on
a first plan none of those identifiers exist yet.

The modules underneath now address those associations by position in
their list rather than by the identifier itself. A list's length is known
even when none of its elements are, so the whole architecture plans and
applies in one pass. The consequence worth knowing is that reordering
`spoke_vpc_cidrs` shifts the associations that follow it, and Terraform
will plan to recreate them — append rather than insert.

The transit gateway is still created with its own default route table
taking every attachment, so the hub routes any-to-any as soon as it
exists, and `replace_existing_association` is what lets the same apply
move the spokes and the VPN onto the inspection route table. That move is
what turns a flat hub into an inspected one.

One route genuinely cannot be written here at all. The firewall's
endpoints are the next hop for traffic arriving in the hub's `attachment`
subnets, and their IDs appear only in the firewall's own status once it
exists. Take the `firewall_endpoint_ids` output and add a route per zone
to the attachment subnets' route tables; until you do, traffic reaches
the hub and stops there. Nothing about a single Terraform configuration
can shorten this, which is why the output exists.

### Things it deliberately does not do

One Trivy finding survives on this configuration by design, and it is
worth stating rather than silently suppressing:

- **No access logging on the log bucket.** The bucket that receives the
  firewall's flow logs does not log access to itself. Pointing it at a
  second bucket, which would then need a third, is a regress with no end.

Two absences are worth naming as well. `auto_accept_shared_attachments`
is left off on the transit gateway, so an account that has been granted
the share still cannot attach a VPC without someone in this account
accepting it — the acceptance step is the only review there is, and
turning it off discards it. And the firewall's rule group drops only what
is unambiguous, leaving everything else to pass with an alert. A policy
that defaults to dropping is the right end state and the wrong starting
point: read the alert log for a fortnight first, then tighten it against
what you actually saw.

## Usage

```hcl
module "network" {
  source  = "kn47ytv9mv/architecture-hybrid/aws"
  version = "~> 1.0"

  name        = "network"
  alarm_email = "network@example.com"
}
```

A hub across three availability zones, joined to an on-premises network,
shared with the rest of the organization, and budgeted:

```hcl
module "network" {
  source = "github.com/kn47ytv9mv/terraform-aws-architecture-hybrid"

  name                    = "network"
  region                  = "us-east-1"
  availability_zone_count = 3

  hub_vpc_cidr = "10.0.0.0/16"

  spoke_vpcs = {
    production = { cidr_block = "10.1.0.0/16" }
    staging    = { cidr_block = "10.2.0.0/16" }
    shared     = { cidr_block = "10.3.0.0/16" }
  }

  on_premises_ip          = "198.51.100.10"
  on_premises_asn         = 65010
  on_premises_cidr        = "172.16.0.0/12"
  on_premises_domain      = "corp.example."
  on_premises_dns_servers = ["172.16.10.53", "172.16.11.53"]

  internal_domain   = "network.internal"
  shared_principals = ["arn:aws:organizations::123456789012:organization/o-abcdefghij"]

  alarm_email    = "network@example.com"
  monthly_budget = "3000"

  tags = {
    Environment = "shared"
  }
}
```

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws | ~> 6.61 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| region | Region every resource in this architecture is created in. | `"us-east-1"` | no |
| name | Name prefix applied to every resource, so one account can hold several copies of this architecture without collision. | `"hybrid"` | no |
| hub_vpc_cidr | IPv4 range for the hub VPC. The hub holds only network infrastructure — transit gateway, firewall, and resolver network interfaces — so it consumes very little of this range, and the spare room is deliberate: appliances added to the hub later are the hardest thing to renumber. | `"10.0.0.0/16"` | no |
| spoke_vpcs | Spoke VPCs to create and attach to the transit gateway, keyed by a short name that appears in the name of everything the spoke owns. Each entry needs a `cidr_block`. The ranges must not overlap one another, the hub, or the on-premises network: a transit gateway routes on destination CIDR alone and cannot tell two identical ranges apart. | `{ workload = { cidr_block = "10.1.0.0/16" }, shared = { cidr_block = "10.2.0.0/16" } }` | no |
| availability_zone_count | Availability zones the hub and every spoke spread across. Two is the minimum this architecture accepts. | `2` | no |
| amazon_side_asn | Private ASN the transit gateway presents on its side of every BGP session. It must differ from `on_premises_asn`, because a BGP session between two devices claiming the same ASN never establishes. | `64512` | no |
| on_premises_ip | Public IP address of the on-premises VPN device. Setting it creates a customer gateway, a site-to-site VPN connection onto the transit gateway, and an alarm on the tunnels. If null, the hub is built without a link to on-premises, which is a reasonable first apply — the VPN can be added afterwards without disturbing anything else. | `null` | no |
| on_premises_asn | BGP ASN of the on-premises VPN device. Only used when `on_premises_ip` is set. | `65000` | no |
| on_premises_cidr | IPv4 range on the on-premises side of the VPN. The hub's resolver subnets route this range over the transit gateway so outbound DNS queries reach the on-premises name servers, and the firewall counts it as part of the internal network rather than the internet. | `"192.168.0.0/16"` | no |
| on_premises_domain | DNS domain the on-premises name servers are authoritative for, as a fully qualified name ending in a dot. Setting it creates a forwarding rule, so queries for that domain from any attached VPC leave through the outbound resolver endpoint instead of being answered — wrongly — by the VPC resolver. If null, no forwarding rule is created and resolution towards on-premises does not work. | `null` | no |
| on_premises_dns_servers | IPv4 addresses of the on-premises name servers the forwarding rule sends queries to. Required when `on_premises_domain` is set. | `[]` | no |
| internal_domain | Domain of the private hosted zone the hub serves. Every VPC in the architecture is associated with it, so a name registered from one spoke resolves from the others and, through the inbound endpoint, from on-premises. | `"hybrid.internal"` | no |
| shared_principals | AWS account IDs, an AWS Organizations organization ARN, or organizational unit ARNs allowed to attach their own VPCs to the transit gateway. If empty, no resource share is created and the transit gateway stays private to this account. | `[]` | no |
| log_retention_days | Days flow logs and firewall alerts are kept in CloudWatch Logs. Network logs are the evidence for an investigation that usually begins weeks after the traffic itself, so shortening this saves very little and costs exactly the records an investigation needs. | `90` | no |
| alarm_email | Address subscribed to the alarm topic. An email subscription stays pending until the recipient confirms it, so alarms deliver nothing until then. | `null` | no |
| monthly_budget | Monthly spend in USD to alarm on, as a string. If null, no budget is created. | `null` | no |
| tags | A map of tags applied to every resource in the architecture. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| transit_gateway_id | The ID of the transit gateway every network in this architecture attaches to. |
| transit_gateway_arn | ARN of the transit gateway, which is what a resource share grants another account access to. |
| hub_vpc_id | The ID of the hub VPC holding the firewall and the resolver endpoints. |
| spoke_vpc_ids | Map of spoke name to the ID of the VPC created for it. |
| hub_route_table_id | The transit gateway route table the hub attachment is associated with once the associations are complete. Every other attachment propagates into it, so the firewall's return traffic finds its destination. |
| inspection_route_table_id | The transit gateway route table whose only route sends every destination to the hub for inspection. Associating attachments with it is the step that turns the flat hub into an inspected one. |
| firewall_endpoint_ids | IDs of the firewall's endpoints, one per availability zone. These are the targets for the routes that send the hub's attachment subnets through the firewall, and they are only known once the firewall exists. |
| inbound_resolver_endpoint_id | The ID of the inbound resolver endpoint, to point on-premises conditional forwarders at. |
| outbound_resolver_endpoint_id | The ID of the outbound resolver endpoint every forwarding rule sends queries through. |
| internal_zone_id | The ID of the private hosted zone every attached VPC resolves against. |
| vpn_connection_id | The ID of the site-to-site VPN connection. Null when no `on_premises_ip` was supplied. |
| vpn_tunnel_addresses | Public addresses of the two VPN tunnels, to configure on the on-premises device. Empty when no `on_premises_ip` was supplied. |
| resource_share_arn | ARN of the resource share granting other accounts access to the transit gateway. Null when no `shared_principals` were supplied. |
| alerts_topic_arn | ARN of the topic every alarm in this architecture notifies. |

## License

MIT — see [LICENSE.md](LICENSE.md).
