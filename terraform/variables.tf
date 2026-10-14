# Every default here mirrors config/poc.config.psd1 so the Terraform and
# PowerShell paths produce the same deployment. If you change one, change both.

#region subscription and resource group ---------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Leave empty to use ARM_SUBSCRIPTION_ID or the current az CLI subscription."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region for every resource."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group that holds the PoC."
  type        = string
  default     = "rg-leostream-poc"
}

variable "create_resource_group" {
  description = <<-EOT
    Whether Terraform owns the resource group.

    true  - Terraform creates it, and "terraform destroy" deletes it along with
            any role assignment scoped to it.
    false - Terraform reads the existing group with a data source and never
            deletes it. Use this once an administrator has granted the Azure
            Center service principal a role on the group, because that
            assignment dies with the group and cannot be recreated without the
            same administrator.

    See Remove-LeostreamPoC.ps1, which keeps the group by default for the same
    reason.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project     = "Leostream-PoC"
    Environment = "PoC"
    ManagedBy   = "Terraform"
  }
}

#endregion

#region network ---------------------------------------------------------------

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-leostream-poc"
}

variable "vnet_address_space" {
  description = "Virtual network address space."
  type        = list(string)
  default     = ["10.50.0.0/16"]
}

variable "subnet_name" {
  description = "Name of the single subnet holding both VMs."
  type        = string
  default     = "snet-leostream"
}

variable "subnet_prefix" {
  description = "Subnet address prefix."
  type        = string
  default     = "10.50.1.0/24"
}

variable "nsg_name" {
  description = "Network security group name."
  type        = string
  default     = "nsg-leostream"
}

variable "allowed_client_cidrs" {
  description = <<-EOT
    Source ranges allowed to reach the Gateway on 443 and 22.

    ["0.0.0.0/0"] is translated to the Internet service tag and exposes the
    Gateway to the whole internet. Narrow this to your own egress address.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_client_cidrs) > 0
    error_message = "allowed_client_cidrs must contain at least one entry."
  }
}

variable "nat_gateway_enabled" {
  description = <<-EOT
    Create a NAT gateway for outbound internet access.

    Keep this true. The Broker has no public IP, and Azure retired default
    outbound access in September 2025, so without a NAT gateway the Broker
    cannot reach the RHEL repositories or the Leostream download site and the
    install fails with repository timeouts.
  EOT
  type        = bool
  default     = true
}

variable "nat_gateway_name" {
  description = "NAT gateway name."
  type        = string
  default     = "natgw-leostream"
}

variable "nat_gateway_idle_timeout_minutes" {
  description = "NAT gateway TCP idle timeout in minutes."
  type        = number
  default     = 10
}

variable "broker_admin_port" {
  description = <<-EOT
    Publishes the Broker's administrator interface on the Gateway's public IP,
    so it can be reached in a browser without an SSH tunnel. The Gateway
    forwards this port straight through to the Broker on 443, so TLS stays
    end-to-end to the Broker.

    Set to null to disable and reach the admin interface only over an SSH
    tunnel.

    SECURITY: this exposes the Leostream administrator console to whatever
    allowed_client_cidrs permits, which defaults to the whole internet. Change
    the Broker's default 'admin' / 'leo' credentials before enabling it.
  EOT
  type        = number
  default     = 8443
}

variable "http_port" {
  description = <<-EOT
    Optional inbound HTTP port opened on the NSG, for the HTTP-to-HTTPS
    redirect and ACME http-01 certificate challenges. Leave null for the PoC,
    where the admin interface is reached over an SSH tunnel on 443.
  EOT
  type        = number
  default     = null
}

#endregion

#region administrative access -------------------------------------------------

variable "admin_username" {
  description = "Linux administrative user created on both VMs."
  type        = string
  default     = "leoadmin"
}

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to the SSH public key authorised on both VMs.

    Azure accepts RSA (2048 bits or more) and ED25519 keys only; ECDSA is
    rejected. Create one with:
      ssh-keygen -t rsa -b 4096 -C "leostream-poc" -f "$HOME/.ssh/id_rsa"
  EOT
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

#endregion

#region virtual machines ------------------------------------------------------

variable "broker_name" {
  description = "Broker VM name."
  type        = string
  default     = "leo-broker-01"
}

variable "broker_size" {
  description = "Broker VM size."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "broker_private_ip" {
  description = "Static private IP of the Broker."
  type        = string
  default     = "10.50.1.10"
}

variable "broker_os_disk_size_gb" {
  description = "Broker OS disk size in GB."
  type        = number
  default     = 128
}

variable "gateway_name" {
  description = "Gateway VM name."
  type        = string
  default     = "leo-gateway-01"
}

variable "gateway_size" {
  description = "Gateway VM size."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "gateway_private_ip" {
  description = "Static private IP of the Gateway."
  type        = string
  default     = "10.50.1.20"
}

variable "gateway_os_disk_size_gb" {
  description = "Gateway OS disk size in GB."
  type        = number
  default     = 64
}

variable "gateway_public_ip_name" {
  description = "Name of the Gateway public IP."
  type        = string
  default     = "pip-leo-gateway-01"
}

variable "os_disk_storage_account_type" {
  description = "Managed disk type for both OS disks."
  type        = string
  default     = "Premium_LRS"
}

variable "rhel_image" {
  description = "RHEL 9 marketplace image for both VMs."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "9-lvm-gen2"
    version   = "latest"
  }
}

#endregion

#region Leostream software ----------------------------------------------------

variable "install_software" {
  description = <<-EOT
    Run the Leostream installers through Azure Run Command after the VMs come
    up. Set to false to provision infrastructure only and install later with
    Install-LeostreamBroker.ps1 and Install-LeostreamGateway.ps1.
  EOT
  type        = bool
  default     = true
}

variable "broker_installer_uri" {
  description = "URI of the Leostream Platform 26 Broker installer."
  type        = string
  default     = "https://downloads.leostream.com/leostream-broker-26.1.6-1.x86_64.rpm"
}

variable "gateway_installer_uri" {
  description = "URI of the Leostream Gateway installer."
  type        = string
  default     = "https://downloads.leostream.com/leostream-gateway-26.1.6-1.x86_64.rpm"
}

variable "skip_os_update" {
  description = "Skip 'dnf update' during installation. Faster, but leaves the OS unpatched."
  type        = bool
  default     = false
}

variable "leostream_license_key" {
  description = <<-EOT
    Optional Leostream licence key. Leave empty and activate in the web
    interface instead. Never commit a value for this; pass it with
    TF_VAR_leostream_license_key.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

#endregion
