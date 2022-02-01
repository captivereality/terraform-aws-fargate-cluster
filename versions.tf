terraform {
  required_version = ">= 0.12"
}

provider "aws" {
  # version = ">= 3.0" # Removed to suppress the " Version constraints inside provider configuration blocks are deprecated" warning
  region  = var.region
}
