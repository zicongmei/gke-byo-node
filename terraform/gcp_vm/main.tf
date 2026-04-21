terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_network" "vpc_network" {
  name                    = "${var.name_prefix}-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_firewall" "ssh" {
  name    = "${var.name_prefix}-allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance" "vm" {
  count        = var.number_of_vms
  name         = "${var.name_prefix}-vm-${count.index}"
  machine_type = "e2-medium"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      // Ephemeral public IP
    }
  }
}
