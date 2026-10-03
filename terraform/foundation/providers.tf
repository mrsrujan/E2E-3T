provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "E2E-3T"
      ManagedBy = "terraform"
      Layer     = "foundation"
    }
  }
}
