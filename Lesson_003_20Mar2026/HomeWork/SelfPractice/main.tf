terraform {
  # Matches your local 1.14.8 and the cloud's 1.14.9
  required_version = "~> 1.14.0"

  cloud {
    organization = "nyurkadu"

    workspaces {
      name = "My_First_Workspace"
    }
  }

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

resource "local_file" "practice" {
  content  = "Hello from Terraform! This is my self-practice."
  filename = "${path.module}/practice.txt"
}

# This block makes the content visible in the "Outputs" tab in the browser
output "file_content_remote" {
  value = local_file.practice.content
}
