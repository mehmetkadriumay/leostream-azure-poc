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

    # Credentials for a Leostream Azure Center (Setup > Centers). Leostream
    # accepts either the Broker's managed identity or an Entra ID application.
    # The application model is the default here because creating one needs no
    # Azure RBAC at all - only the final role assignment does, and that can be
    # handed to an administrator as a single command.
    #
    # Configure-LeostreamAzureCenter.ps1 creates the application, the service
    # principal and the secret. No secret is ever stored in this file.
    AzureCenter = @{
        AppDisplayName    = 'leostream-poc-azure-center'

        # Contributor is what Leostream needs to create, power-manage and
        # delete desktop VMs. Narrow it to a custom role for production.
        RoleName          = 'Contributor'

        # Client secret lifetime in months (1-24).
        SecretValidMonths = 12
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

        # The Broker has no public IP, and Azure retired default outbound
        # internet access on 30 September 2025. Without a NAT gateway it cannot
        # reach the RHUI, EPEL or Leostream download endpoints, so the install
        # fails with repository timeouts. A NAT gateway gives outbound-only
        # access: nothing on the internet can initiate a connection inward.
        #
        # Billed per hour plus data processed (roughly USD 32/month in most
        # regions). Remove-LeostreamPoC.ps1 deletes it with the resource group.
        # Set to $false only if you provide outbound access another way.
        NatGatewayEnabled    = $true
        NatGatewayName       = 'natgw-leostream'
        NatGatewayPublicIp   = 'pip-natgw-leostream'
        NatGatewayIdleMinutes = 10
    }

    # Source ranges allowed to reach the Gateway's public IP on 443 (users)
    # and 22 (you, for administration). Narrow this to your own egress IP.
    AllowedClientCidrs = @(
        '0.0.0.0/0'
    )

    VirtualMachines = @{
        Broker = @{
            Name            = 'leo-broker-01'

            # Leostream's floor for a Connection Broker is 2 vCPU, 8 GB RAM and
            # 20 GB of disk, on RHEL 9.6 or later (or Rocky/AlmaLinux). RHEL 8
            # and CentOS Stream 9 are not supported and cannot be upgraded into.
            #
            # In a cloud the hypervisor reserves part of the instance, so an
            # exactly-8 GB size trips the Broker's own health checks. D4s_v5
            # (4 vCPU, 16 GB) is the smallest comfortable choice; D2s_v5 is
            # exactly 8 GB and will warn. Test-LeostreamPoC.ps1 checks this.
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
        # Public half of the SSH key deployed to both RHEL VMs. The matching
        # private key is what you pass to 'ssh -i' afterwards.
        # Create it with:
        #   ssh-keygen -t rsa -b 4096 -C "leostream-poc" -f "$HOME\.ssh\id_rsa"
        # Azure accepts RSA (>=2048 bits) and ED25519 only; ECDSA is rejected.
        # Set before the first deployment - changing it later does not re-key
        # a VM that already exists.
        SshPublicKeyPath = '~/.ssh/id_rsa.pub'
    }

    Ports = @{
        Https = 443
        Ssh   = 22

        # Leostream also lists inbound 80 for the HTTP-to-HTTPS redirect on the
        # administrator interface, and it is what certbot needs to answer an
        # ACME http-01 challenge if you replace the self-signed certificate.
        # This PoC reaches the admin UI over an SSH tunnel on 443, so 80 is not
        # opened. Set this to 80 if you want the rule.
        Http  = $null
    }
}
