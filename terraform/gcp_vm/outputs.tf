output "ssh_commands" {
  value = [
    for instance in google_compute_instance.vm :
    "gcloud compute ssh ${instance.name} --zone ${instance.zone} --project ${var.project_id}"
  ]
}
