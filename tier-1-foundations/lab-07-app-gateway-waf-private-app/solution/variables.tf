variable "subscription_id" {
  description = "Target subscription. Leave null and set ARM_SUBSCRIPTION_ID instead."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for every resource in this lab."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group holding the whole lab."
  type        = string
  default     = "rg-lab07"
}

variable "vnet_name" {
  description = "Virtual network name."
  type        = string
  default     = "vnet-lab07"
}

variable "vnet_address_space" {
  description = "Address space for the lab virtual network."
  type        = string
  default     = "10.70.0.0/16"
}

variable "name_suffix" {
  description = "Suffix for the globally unique web app and Key Vault names. Empty means random."
  type        = string
  default     = ""
}

variable "waf_mode" {
  description = <<-EOT
    Prevention blocks attacks. Detection logs them and serves the request anyway.
    Set to "Detection" and re-apply to watch the injection payload sail straight
    through - that is the difference this one word makes, and it is the reason so
    many production gateways protect nothing.
  EOT
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Prevention", "Detection"], var.waf_mode)
    error_message = "waf_mode must be either Prevention or Detection."
  }
}

variable "certificate_subject" {
  description = "Subject of the self-signed certificate the gateway presents."
  type        = string
  default     = "CN=lab07.local"
}

variable "role_propagation_delay" {
  description = <<-EOT
    How long to wait after granting the Key Vault roles before using them. Role
    assignments are eventually consistent and certificate creation fails if you
    are too quick.
  EOT
  type        = string
  default     = "60s"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    lab = "07-app-gateway-waf-private-app"
  }
}
