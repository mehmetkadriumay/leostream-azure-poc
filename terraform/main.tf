locals {
  # 0.0.0.0/0 is not a valid NSG source. Azure expresses "anywhere on the
  # internet" as a service tag, which is what Deploy-LeostreamPoC.ps1 does too.
  allowed_clients = contains(var.allowed_client_cidrs, "0.0.0.0/0") ? ["Internet"] : var.allowed_client_cidrs

  # A service tag or a single CIDR goes in the singular attribute; only a real
  # list of CIDRs goes in the plural one.
  nsg_source_prefix   = length(local.allowed_clients) == 1 ? local.allowed_clients[0] : null
  nsg_source_prefixes = length(local.allowed_clients) > 1 ? local.allowed_clients : null

  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  location            = var.create_resource_group ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location

  # Only these rules are needed. Azure's default rules already allow all traffic
  # within the virtual network (Gateway to Broker) and deny everything else
  # inbound from the internet.
  base_nsg_rules = [
    {
      name        = "Allow-HTTPS-Inbound"
      description = "Leostream Gateway HTTPS and remote viewer traffic"
      priority    = 100
      port        = "443"
    },
    {
      name        = "Allow-SSH-Inbound"
      description = "Administrative SSH to the Gateway (the Broker has no public IP)"
      priority    = 110
      port        = "22"
    },
  ]

  http_nsg_rule = var.http_port == null ? [] : [
    {
      name        = "Allow-HTTP-Inbound"
      description = "HTTP-to-HTTPS redirect and ACME http-01 certificate challenges"
      priority    = 120
      port        = tostring(var.http_port)
    },
  ]

  nsg_rules = concat(local.base_nsg_rules, local.http_nsg_rule)
}

#region resource group ---------------------------------------------------------

resource "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = var.resource_group_name
}

#endregion

#region network security group -------------------------------------------------

resource "azurerm_network_security_group" "this" {
  name                = var.nsg_name
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = local.nsg_rules
    content {
      name                       = security_rule.value.name
      description                = security_rule.value.description
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_address_prefix      = local.nsg_source_prefix
      source_address_prefixes    = local.nsg_source_prefixes
      source_port_range          = "*"
      destination_address_prefix = var.subnet_prefix
      destination_port_range     = security_rule.value.port
    }
  }
}

#endregion

#region NAT gateway ------------------------------------------------------------

# The Broker has no public IP. Azure retired default outbound access on
# 30 September 2025, so without this the Broker has no route to the RHEL
# repositories or downloads.leostream.com and the install fails.

resource "azurerm_public_ip" "nat" {
  count = var.nat_gateway_enabled ? 1 : 0

  name                = "pip-${var.nat_gateway_name}"
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.nat_gateway_enabled ? 1 : 0

  name                    = var.nat_gateway_name
  location                = local.location
  resource_group_name     = local.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.nat_gateway_idle_timeout_minutes
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.nat_gateway_enabled ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

#endregion

#region virtual network --------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  location            = local.location
  resource_group_name = local.resource_group_name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  name                 = var.subnet_name
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  count = var.nat_gateway_enabled ? 1 : 0

  subnet_id      = azurerm_subnet.this.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id

  # The gateway is useless until it owns a public IP, and associating both at
  # once occasionally races.
  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}

#endregion

#region network interfaces -----------------------------------------------------

resource "azurerm_public_ip" "gateway" {
  name                = var.gateway_public_ip_name
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "broker" {
  name                = "nic-${var.broker_name}"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.broker_private_ip
  }
}

resource "azurerm_network_interface" "gateway" {
  name                = "nic-${var.gateway_name}"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.gateway_private_ip
    public_ip_address_id          = azurerm_public_ip.gateway.id
  }
}

#endregion

#region virtual machines -------------------------------------------------------

resource "azurerm_linux_virtual_machine" "broker" {
  name                  = var.broker_name
  computer_name         = var.broker_name
  location              = local.location
  resource_group_name   = local.resource_group_name
  size                  = var.broker_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.broker.id]
  tags                  = var.tags

  # Password authentication is never enabled; the SSH key is the only credential.
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-${var.broker_name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.broker_os_disk_size_gb
  }

  source_image_reference {
    publisher = var.rhel_image.publisher
    offer     = var.rhel_image.offer
    sku       = var.rhel_image.sku
    version   = var.rhel_image.version
  }

  # The Broker uses this identity to enumerate and control Azure VMs once an
  # administrator grants it a role. See Configure-LeostreamAzureCenter.ps1 for
  # the service-principal alternative.
  identity {
    type = "SystemAssigned"
  }

  # Without an egress path the VM provisions but every later install step fails
  # on repository timeouts, so make the dependency explicit.
  depends_on = [
    azurerm_subnet_nat_gateway_association.this,
    azurerm_subnet_network_security_group_association.this,
  ]
}

resource "azurerm_linux_virtual_machine" "gateway" {
  name                  = var.gateway_name
  computer_name         = var.gateway_name
  location              = local.location
  resource_group_name   = local.resource_group_name
  size                  = var.gateway_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.gateway.id]
  tags                  = var.tags

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-${var.gateway_name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.gateway_os_disk_size_gb
  }

  source_image_reference {
    publisher = var.rhel_image.publisher
    offer     = var.rhel_image.offer
    sku       = var.rhel_image.sku
    version   = var.rhel_image.version
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.this,
  ]
}

#endregion
