terraform {
  required_version = ">= 1.6"

  backend "s3" {
    # Overridden by terraform init -backend-config=... if desired.
    # Values below must match what bootstrap.sh created.
    bucket = "e2e3t-tfstate-640584914236"
    key    = "foundation/terraform.tfstate"
    region = "us-east-1"
    #dynamodb_table = "e2e3t-tflocks"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}
