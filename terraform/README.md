# Terraform deployment

This is a Terraform equivalent of the PowerShell deployment. `terraform apply`
produces the same PoC as `Deploy-LeostreamPoC.ps1` followed by
`Install-LeostreamBroker.ps1` and `Install-LeostreamGateway.ps1`: a working
Leostream Broker and Gateway.

Use one path or the other, not both at once. They create identically named
resources, so running Terraform against a PowerShell-built deployment will try
to recreate everything (see [Adopting an existing deployment](#adopting-an-existing-deployment)).

## What it creates

| Resource | Name | Notes |
| --- | --- | --- |
| Resource group | `rg-leostream-poc` | Created or referenced, see below |
| Network security group | `nsg-leostream` | Inbound 443 and 22 from `allowed_client_cidrs` |
| Public IP | `pip-natgw-leostream` | Standard, static, outbound only |
| NAT gateway | `natgw-leostream` | Egress for the Broker |
| Virtual network | `vnet-leostream-poc` | `10.50.0.0/16` |
| Subnet | `snet-leostream` | `10.50.1.0/24`, NSG and NAT associated |
| Public IP | `pip-leo-gateway-01` | Standard, static, inbound |
| NSG rule | `Allow-Broker-Admin-Inbound` | Port 8443, forwarded to the Broker; disable with `broker_admin_port = null` |
| Network interfaces | `nic-leo-broker-01`, `nic-leo-gateway-01` | Static private IPs |
| Virtual machine | `leo-broker-01` | RHEL 9, `10.50.1.10`, no public IP, system-assigned identity |
| Virtual machine | `leo-gateway-01` | RHEL 9, `10.50.1.20`, public IP |
| Run commands | `install-leostream-broker`, `install-leostream-gateway` | Software install, skip with `install_software = false` |

Every default in `variables.tf` mirrors `config/poc.config.psd1`. If you change
one, change the other, otherwise the two deployment paths drift apart.

## Prerequisites

- Terraform 1.5 or later
- Azure CLI, logged in with `az login`
- An SSH key pair. Azure accepts **RSA (2048 bits or more)** and **ED25519**
  only; ECDSA is rejected. If you do not have one:

  ```powershell
  ssh-keygen -t rsa -b 4096 -C "leostream-poc" -f "$HOME\.ssh\id_rsa"
  ```

  > [!WARNING]
  > If `id_rsa` already exists, `ssh-keygen` overwrites it and anything
  > authorised by the old key becomes unreachable. Check first with
  > `Get-ChildItem $HOME\.ssh\id_rsa.pub`.

## Deploy

```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars   # optional
terraform init
terraform plan
terraform apply
```

Expect roughly 25 to 45 minutes, most of it the `dnf update` and the Leostream
installers. Set `skip_os_update = true` to trade patching for speed.

### Select a subscription

Terraform uses the Azure CLI subscription by default. To be explicit:

```powershell
az account set --subscription "<subscription-id>"
# or
$env:ARM_SUBSCRIPTION_ID = "<subscription-id>"
```

### Supply a licence key

Never put a licence key in a `.tfvars` file. Pass it through the environment so
it stays out of the repository:

```powershell
$env:TF_VAR_leostream_license_key = "<key>"
terraform apply
```

Terraform marks this variable sensitive, so the generated install script is
redacted in plan output. It is still written to state in plain text, which is
why `*.tfstate` is gitignored. Leave it empty to activate the licence in the
web interface instead.

## After deploying

```powershell
terraform output
```

| Output | Use |
| --- | --- |
| `gateway_public_ip` | Inbound address of the Gateway |
| `broker_admin_url` | Broker console in a browser, no tunnel needed |
| `ssh_to_gateway` | Administrative session on the Gateway |
| `ssh_to_broker` | Jump through the Gateway to the Broker |
| `broker_admin_tunnel` | Tunnel, then browse `https://localhost:8443/` |
| `broker_identity_principal_id` | Object ID to grant a role to |
| `grant_broker_role_command` | The role assignment an administrator must run |

The Broker starts at the default credentials `admin` / `leo`. Change them at
first sign-in.

> [!WARNING]
> `broker_admin_port` defaults to `8443`, which publishes the Broker's
> administrator console on the Gateway's public IP so you can reach it without
> an SSH tunnel. Combined with the default `allowed_client_cidrs` of
> `0.0.0.0/0`, that puts the console on the open internet. Change the Broker
> password immediately, narrow `allowed_client_cidrs`, or set
> `broker_admin_port = null` to disable it.

The Gateway publishes it with a firewalld TCP forward to the Broker on 443, so
TLS terminates on the Broker and you will see the `CN=leo-broker-01`
certificate. An HTTP reverse proxy is not used, because the Gateway's
`leo.conf` declares its `<Location>` blocks globally and a new vhost would
inherit the `/app/...` handlers the Broker's UI also needs.

Validate the result with the existing PowerShell test script, which is
deployment-method agnostic:

```powershell
..\scripts\Test-LeostreamPoC.ps1
```

> [!NOTE]
> Public IPs are released when they are destroyed, so the Gateway address
> changes on every rebuild. Update `~/.ssh/config` and remove the stale entries
> from `known_hosts` afterwards, or SSH refuses to connect with
> `REMOTE HOST IDENTIFICATION HAS CHANGED`:
> ```powershell
> ssh-keygen -R <old-gateway-ip>
> ssh-keygen -R 10.50.1.10
> ```

## The resource group and `terraform destroy`

This is the one setting worth understanding before you run anything.

`create_resource_group` controls whether Terraform owns `rg-leostream-poc`.

- **`true` (default)** — Terraform creates the group, and `terraform destroy`
  deletes it.
- **`false`** — Terraform reads the existing group with a data source and never
  deletes it. The group must already exist.

Set it to `false` once an administrator has granted the Broker's managed
identity, or the Azure Center service principal, a role on the resource group.
**A role assignment is destroyed along with its resource group**, and recreating
a group with the same name does not bring it back; you need that administrator
again. `Remove-LeostreamPoC.ps1` keeps the group by default for exactly this
reason.

```powershell
terraform destroy -var 'create_resource_group=false'
```

To stop Terraform managing a group it already created, without deleting it:

```powershell
terraform state rm azurerm_resource_group.this[0]
```

Then set `create_resource_group = false` in `terraform.tfvars`.

## Adopting an existing deployment

Terraform only knows about resources in its state file. Pointing it at a
deployment built by `Deploy-LeostreamPoC.ps1` produces a plan that recreates
everything and fails on name conflicts. Either tear the old one down first:

```powershell
..\scripts\Remove-LeostreamPoC.ps1
```

or import the resources, starting with the group and working outwards:

```powershell
terraform import azurerm_virtual_network.this "/subscriptions/<sub>/resourceGroups/rg-leostream-poc/providers/Microsoft.Network/virtualNetworks/vnet-leostream-poc"
```

Tearing down is almost always quicker for a PoC.

## Azure Center integration

Terraform does not create the Entra application. Managed identity is the
recommended route and the Broker already has one; grant it a role with the
`grant_broker_role_command` output. If you need a service principal with a
client secret instead, use `..\scripts\Configure-LeostreamAzureCenter.ps1`,
which deliberately keeps secret creation out of Terraform state.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Failed to download metadata for repo ...` / `Curl error (28)` in the Broker run command | The Broker has no outbound path. Confirm `nat_gateway_enabled = true` and that `azurerm_subnet_nat_gateway_association.this` exists. Azure retired default outbound access in September 2025. |
| `linuxConfiguration.ssh.publicKeys.keyData is invalid` | The key is not RSA 2048+ or ED25519. Check with `ssh-keygen -l -f $HOME\.ssh\id_rsa.pub`. |
| `A resource with the ID ... already exists` | The deployment exists but is not in Terraform state. See [Adopting an existing deployment](#adopting-an-existing-deployment). |
| `subscription_id is required` | Run `az login`, then `az account set --subscription <id>`, or set `ARM_SUBSCRIPTION_ID`. |
| Run command reports success but Leostream is not serving | Run command reports the *execution*, not the install result. Read the output: `az vm run-command show --resource-group rg-leostream-poc --vm-name leo-broker-01 --name install-leostream-broker --instance-view` |
| `broker_admin_url` times out while 443 works | Source address not in `allowed_client_cidrs`, or the forward is missing. Check `sudo firewall-cmd --list-forward-ports` on the Gateway. |
| TLS fails on 8443 although TCP connects | `masquerade` is off, so the Broker answers you directly and the reply is dropped as asymmetric. `sudo firewall-cmd --permanent --add-masquerade; sudo firewall-cmd --reload` |
| `Error: creating Resource Group: ... already exists` | Set `create_resource_group = false`. |

To re-run an installer after changing a script, taint the run command:

```powershell
terraform apply -replace='azurerm_virtual_machine_run_command.broker[0]'
```
