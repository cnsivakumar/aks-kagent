terraform {
  backend "azurerm" {
    use_azuread_auth     = true
    resource_group_name  = "terraformairg"
    storage_account_name = "terraformstgacc01"
    container_name       = "terraformstate"
    key                  = "dev.terraform.tfstate"
  }
}