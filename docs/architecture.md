# Architecture

## Design goal

The smallest topology that still demonstrates Leostream Platform 26 running on
Azure with a real managed-identity integration. Two virtual machines, one subnet,
one network security group. Every piece that is not needed to prove the concept
has been left out.

## Topology

```mermaid
flowchart TB
    user([Remote user])
    admin([Administrator])
    arm([Azure Resource Manager])

    subgraph rg["Resource group: rg-leostream-poc"]
        subgraph vnet["vnet-leostream-poc · 10.50.0.0/16"]
            subgraph sn["snet-leostream · 10.50.1.0/24 · nsg-leostream"]
                gw["leo-gateway-01<br/>RHEL 9 · Standard_D2s_v5<br/>10.50.1.20 + public IP"]
                broker["leo-broker-01<br/>RHEL 9 · Standard_D4s_v5<br/>10.50.1.10 · private only"]
            end
        end
    end

    user -->|TCP 443| gw
    admin -->|TCP 22| gw
    gw -->|TCP 443| broker
    gw -->|SSH hop| broker
    broker -->|system-assigned<br/>managed identity| arm
```

## Resources

| Resource | Name | Notes |
|---|---|---|
| Resource group | `rg-leostream-poc` | Tagged `project=leostream-poc`; the teardown script keys off this tag |
| Virtual network | `vnet-leostream-poc` | `10.50.0.0/16` |
| Subnet | `snet-leostream` | `10.50.1.0/24`, holds both VMs |
| Network security group | `nsg-leostream` | Attached to the subnet |
| Public IP | `pip-leo-gateway-01` | Standard SKU, static, Gateway only |
| Virtual machine | `leo-broker-01` | RHEL 9, private, system-assigned managed identity |
| Virtual machine | `leo-gateway-01` | RHEL 9, public IP |

Broker and Gateway are separate VMs by design. `Deploy-LeostreamPoC.ps1` throws
if the two names in config are identical, and `Test-LeostreamPoC.ps1` checks the
same thing after the fact.

## Network security

`nsg-leostream` carries exactly two explicit rules:

| Priority | Name | Direction | Source | Destination | Port |
|---|---|---|---|---|---|
| 100 | `Allow-HTTPS-Inbound` | Inbound | `AllowedClientCidrs` | `10.50.1.0/24` | 443 |
| 110 | `Allow-SSH-Inbound` | Inbound | `AllowedClientCidrs` | `10.50.1.0/24` | 22 |

Nothing else is required, because Azure's default rules already provide what is
needed:

| Priority | Default rule | Effect here |
|---|---|---|
| 65000 | `AllowVnetInBound` | Gateway reaches the Broker on 443 and 22 without an explicit rule |
| 65001 | `AllowAzureLoadBalancerInBound` | Health probes |
| 65500 | `DenyAllInBound` | Everything else from the internet is dropped |

The Broker has no public IP, so the two inbound rules only ever match traffic
aimed at the Gateway.

> **Note:** these rules are only as safe as `AllowedClientCidrs`. The shipped
> default of `0.0.0.0/0` exposes both HTTPS *and* SSH to the entire internet.
> Narrow it to your own egress IP before deploying.

## Traffic flows

| Flow | Path | Port |
|---|---|---|
| User → Gateway | Internet → public IP | 443 |
| Gateway → Broker | Inside the VNet | 443 |
| Administrator → Gateway | Internet → public IP | 22 |
| Administrator → Broker | SSH jump through the Gateway | 22 |
| Administrator → Broker UI | SSH local forward through the Gateway | 443 → localhost:8443 |
| Broker → Azure | Outbound HTTPS to Azure Resource Manager | 443 |
| Both VMs → Azure control plane | RunCommand via the guest agent, outbound only | 443 |

## Identity

`leo-broker-01` is created with a system-assigned managed identity
(`New-AzVMConfig -IdentityType SystemAssigned`).

That identity is deliberately left **with no role assignment**. A role would let
the Broker discover, start and stop desktop VMs through an Azure center, and this
PoC deploys no desktops — so the permission would grant power over the
subscription that nothing uses. Creating the identity but not assigning a role
keeps the groundwork in place at zero privilege.

If desktops are added later, someone holding **User Access Administrator** or
**Owner** grants the identity **Virtual Machine Contributor** on the resource
group. Note that this cannot be self-served from a Contributor account, and many
subscriptions apply an ABAC condition that further restricts which roles a
delegated administrator may assign.

No service principal is created and no secret is stored anywhere — in this
repository, in the VM, or in the Broker configuration.

## Deliberate omissions

| Not deployed | Why | Consequence |
|---|---|---|
| Azure Bastion | Roughly doubles the cost of the PoC and takes 10–20 minutes to provision | Administration is over SSH to the Gateway's public IP |
| Separate subnets per tier | Two VMs do not need network segmentation to prove the concept | Gateway and Broker are not isolated from each other |
| Desktop VMs | The largest cost item, and not needed to prove the control plane | Pools, policies and end-to-end sessions are not exercised |
| A role assignment for the Broker identity | Nothing to manage without desktops, and granting roles needs User Access Administrator, which a Contributor cannot self-serve | No Azure center; the identity exists at zero privilege |
| Explicit deny rules | Azure already denies inbound by default at 65500 | None — the effective behaviour is identical |
| Trusted Launch / vTPM | Extra configuration surface for no PoC benefit | VMs use the standard security type |

## What a production design would change

* Gateway and Broker in separate subnets, each with its own NSG.
* Azure Bastion or a VPN gateway for administration; no public SSH.
* Broker and Gateway deployed as HA pairs behind a load balancer.
* A trusted TLS certificate and a real DNS name on the Gateway.
* Desktops in a dedicated subnet with no outbound internet access.
* Diagnostic settings, Defender for Cloud and Azure Monitor across the board.
* A narrower custom role for the Broker identity than Virtual Machine Contributor.
