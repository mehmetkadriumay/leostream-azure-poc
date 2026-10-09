@{
    # ---------------------------------------------------------------------
    # Leostream Platform 26 - Azure Proof of Concept configuration
    #
    # Two virtual machines in one subnet. Nothing else.
    #
    # This file contains NO secrets. Passwords, licence keys and serial
    # numbers are supplied at run time (parameters, prompts, environment
    # variables or Azure Key Vault).
    # ---------------------------------------------------------------------

    Azure = @{
        # Leave SubscriptionId empty to use the current Az context.
        SubscriptionId    = ''
        Location          = 'westeurope'
        ResourceGroupName = 'rg-leostream-poc'
        Tags              = @{
            project     = 'leostream-poc'
            environment = 'poc'
            lifecycle   = 'temporary'
        }
    }

    Leostream = @{
        # Public download locations for the installer packages. These are URLs,
        # not credentials - no serial number or licence key is involved, and no
        # installer is committed to this repository.
        #
        # Pin the versions you intend to test. Override at run time with the
        # -InstallerUri parameter on either install script.
        BrokerInstallerUri  = 'https://downloads.leostream.com/leostream-broker-26.1.6-1.x86_64.rpm'
        GatewayInstallerUri = 'https://downloads.leostream.com/leostream-gateway-2026.1.1-2.x86_64.rpm'
    }

    Network = @{
        VNetName     = 'vnet-leostream-poc'
        AddressSpace = '10.50.0.0/16'

        # A single subnet holds both VMs. Azure's default rules already allow
        # all traffic inside the virtual network, so the Gateway reaches the
        # Broker without any explicit NSG rule.
        SubnetName   = 'snet-leostream'
        SubnetPrefix = '10.50.1.0/24'
        NsgName      = 'nsg-leostream'
    }

    # Source ranges allowed to reach the Gateway's public IP on 443 (users)
    # and 22 (you, for administration). Narrow this to your own egress IP.
    AllowedClientCidrs = @(
        '0.0.0.0/0'
    )

    VirtualMachines = @{
        Broker = @{
            Name            = 'leo-broker-01'
            Size            = 'Standard_D4s_v5'
            PrivateIp       = '10.50.1.10'
            PublicIp        = $false
            ManagedIdentity = $true
            Image           = @{
                Publisher = 'RedHat'
                Offer     = 'RHEL'
                Sku       = '9-lvm-gen2'
                Version   = 'latest'
            }
            OsDiskSizeGb    = 128
            OsDiskType      = 'Premium_LRS'
        }

        Gateway = @{
            Name            = 'leo-gateway-01'
            Size            = 'Standard_D2s_v5'
            PrivateIp       = '10.50.1.20'
            PublicIp        = $true
            PublicIpName    = 'pip-leo-gateway-01'
            DnsLabelPrefix  = ''   # optional, must be globally unique if set
            ManagedIdentity = $false
            Image           = @{
                Publisher = 'RedHat'
                Offer     = 'RHEL'
                Sku       = '9-lvm-gen2'
                Version   = 'latest'
            }
            OsDiskSizeGb    = 64
            OsDiskType      = 'Premium_LRS'
        }
    }

    Admin = @{
        LinuxUsername    = 'leoadmin'
        # Path to an existing SSH public key used for both RHEL VMs.
        SshPublicKeyPath = '~/.ssh/id_rsa.pub'
    }

    Ports = @{
        Https = 443
        Ssh   = 22
    }
}
