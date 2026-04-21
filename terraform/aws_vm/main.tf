terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "google" {
  project = var.gcp_project_id
}

data "aws_caller_identity" "current" {}

# --- AWS IAM for the VM ---
resource "aws_iam_role" "vm_role" {
  name = "${var.name_prefix}-vm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "vm_profile" {
  name = "${var.name_prefix}-vm-profile"
  role = aws_iam_role.vm_role.name
}

# --- GCP Workload Identity Federation ---
resource "google_iam_workload_identity_pool" "pool" {
  workload_identity_pool_id = "${var.name_prefix}-pool"
  display_name              = "AWS Pool for ${var.name_prefix}"
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "${var.name_prefix}-aws-provider"
  display_name                       = "AWS Provider"
  
  attribute_mapping = {
    "google.subject"        = "assertion.arn"
    "attribute.aws_role"    = "assertion.arn.contains('role/') ? assertion.arn.extract('role/{role_name}/') : assertion.arn"
    "attribute.aws_account" = "assertion.account"
  }

  aws {
    account_id = data.aws_caller_identity.current.account_id
  }
}

# --- GCP Service Account for Image Pulling ---
resource "google_service_account" "image_puller" {
  account_id   = "${var.name_prefix}-puller"
  display_name = "GKE Image Puller for AWS Nodes"
}

# Grant puller permissions (GCR/Artifact Registry)
resource "google_project_iam_member" "registry_viewer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.image_puller.email}"
}

# Allow AWS Role to impersonate the GCP Service Account
resource "google_service_account_iam_member" "wif_user" {
  service_account_id = google_service_account.image_puller.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.aws_role/${aws_iam_role.vm_role.name}"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.name_prefix}-subnet"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name = "${var.name_prefix}-rt"
  }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

resource "aws_security_group" "ssh" {
  name        = "${var.name_prefix}-ssh-sg"
  description = "Allow SSH inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.name_prefix}-key"
  public_key = file(pathexpand("~/.ssh/id_rsa.pub"))
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "vm" {
  count         = var.number_of_vms
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.main.id
  key_name      = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.ssh.id]

  tags = {
    Name = "${var.name_prefix}-vm-${count.index}"
  }
}
