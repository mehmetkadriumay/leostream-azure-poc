@{
    # ---------------------------------------------------------------------
    # Leostream Platform 26 - Azure Proof of Concept configuration
    #
    # This file contains NO secrets. Passwords, licence keys, serial numbers
    # and installer locations are supplied at run time (parameters, prompts,
    # environment variables or Azure Key Vault).
    # ---------------------------------------------------------------------

    Azure = @{
        # Leave SubscriptionId empty to use the current Az context.
        SubscriptionId    = ''
        Location          = 'westeurope'
        ResourceGroupName = 'rg-leostream-poc'
        Tags              = @{
            project     = 'leostream-poc'
            environment = 'poc'
            owner       = 'platform-team'
            lifecycle   = 'temporary'
        }
    }

    Network = @{
        VNetName      = 'vnet-leostream-poc'
        AddressSpace  = '10.50.0.0/16'

        Subnets = @{
            Gateway = @{
                Name          = 'snet-gateway'
                AddressPrefix = '10.50.1.0/24'
                NsgName       = 'nsg-gateway'
            }
            Infrastructure = @{
                Name          = 'snet-infrastructure'
                AddressPrefix = '10.50.2.0/24'
                NsgName       = 'nsg-infrastructure'
            }
            Desktop = @{
                Name          = 'snet-desktop'
                AddressPrefix = '10.50.10.0/24'
                NsgName       = 'nsg-desktop'
            }
            Bastion = @{
                # The name AzureBastionSubnet is mandated by Azure.
                Name          = 'AzureBastionSubnet'
                AddressPrefix = '10.50.20.0/26'
                NsgName       = ''
            }
        }
    }

    Bastion = @{
        Enabled        = $true
        Name           = 'bastion-leostream-poc'
        PublicIpName   = 'pip-bastion-leostream-poc'
        Sku            = 'Basic'
    }

    # Source ranges allowed to reach the Gateway's public HTTPS endpoint.
    # '*' is intentionally NOT the default - narrow this to your own egress IPs.
    AllowedClientCidrs = @(
        '0.0.0.0/0'
    )

    VirtualMachines = @{
        Broker = @{
            Name           = 'leo-broker-01'
            Role           = 'Broker'
            Size           = 'Standard_D4s_v5'
            Subnet         = 'Infrastructure'
            PrivateIp      = '10.50.2.10'
            PublicIp       = $false
            OsType         = 'Linux'
            ManagedIdentity = $true
            Image          = @{
                Publisher = 'RedHat'
                Offer     = 'RHEL'
                Sku       = '9-lvm-gen2'
                Version   = 'latest'
            }
            OsDiskSizeGb   = 128
            OsDiskType     = 'Premium_LRS'
            # 'Standard' or 'TrustedLaunch'
            SecurityType   = 'Standard'
        }

        Gateway = @{
            Name           = 'leo-gateway-01'
            Role           = 'Gateway'
            Size           = 'Standard_D2s_v5'
            Subnet         = 'Gateway'
            PrivateIp      = '10.50.1.10'
            PublicIp       = $true
            PublicIpName   = 'pip-leo-gateway-01'
            DnsLabelPrefix = ''   # optional, must be globally unique if set
            OsType         = 'Linux'
            ManagedIdentity = $false
            Image          = @{
                Publisher = 'RedHat'
                Offer     = 'RHEL'
                Sku       = '9-lvm-gen2'
                Version   = 'latest'
            }
            OsDiskSizeGb   = 64
            OsDiskType     = 'Premium_LRS'
            SecurityType   = 'Standard'
        }

        WindowsDesktop = @{
            Name           = 'leo-win-01'
            Role           = 'Desktop'
            Size           = 'Standard_D4s_v5'
            Subnet         = 'Desktop'
            PrivateIp      = '10.50.10.10'
            PublicIp       = $false
            OsType         = 'Windows'
            ManagedIdentity = $false
            Image          = @{
                Publisher = 'MicrosoftWindowsDesktop'
                Offer     = 'windows-11'
                Sku       = 'win11-23h2-pro'
                Version   = 'latest'
            }
            OsDiskSizeGb   = 128
            OsDiskType     = 'Premium_LRS'
            # Windows 11 marketplace images are Gen2 and require Trusted Launch.
            SecurityType   = 'TrustedLaunch'
        }
    }

    Admin = @{
        LinuxUsername   = 'leoadmin'
        WindowsUsername = 'leoadmin'
        # Path to an existing SSH public key used for the RHEL VMs.
        SshPublicKeyPath = '~/.ssh/id_rsa.pub'
    }

    Rbac = @{
        # Role granted to the Broker's system-assigned managed identity so it
        # can discover, start, stop and (optionally) provision desktop VMs.
        RoleDefinitionName = 'Virtual Machine Contributor'
        # Scope: 'ResourceGroup' or 'Subscription'
        Scope              = 'ResourceGroup'
    }

    Ports = @{
        LeostreamGatewayHttps = 443
        LeostreamBrokerHttps  = 443
        # Gateway -> Broker / desktops
        Rdp                   = 3389
        Ssh                   = 22
    }
}
