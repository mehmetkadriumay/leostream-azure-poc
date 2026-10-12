terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  # Leave subscription_id empty to fall back to ARM_SUBSCRIPTION_ID or the
  # subscription selected with "az account set".
  subscription_id = var.subscription_id != "" ? var.subscription_id : null

  features {
    resource_group {
      # Terraform only ever deletes a resource group it created itself, and by
      # then it has already destroyed everything it manages inside it. Without
      # this, a stray resource created outside Terraform blocks the destroy.
      prevent_deletion_if_contains_resources = false
    }

    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}
