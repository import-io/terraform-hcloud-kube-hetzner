locals {
  user_kustomization_templates = try(fileset(var.extra_kustomize_folder, "**/*.yaml.tpl"), toset([]))

  # tofu hides a remote-exec provisioner's output whenever anything in its config or
  # connection is sensitive. The deploy connection's SSH keys are sensitive (ssh_private_key
  # is a `sensitive` variable; ssh_agent_identity inherits the mark via a comparison against
  # it), which otherwise suppresses the `kubectl apply -k` output/errors entirely — that is
  # exactly why a failed reconcile is invisible. These keys are only used to open the SSH
  # session: they are never echoed into stdout, and provisioner connections are not persisted
  # in state, so stripping the sensitive mark here reveals the apply output while leaking
  # nothing. `try(nonsensitive(x), x)` strips the mark whether or not x is currently sensitive
  # and never errors (nonsensitive() errors on non-sensitive input -> try falls back).
  # Actual secrets (extra_kustomize_deployment_commands) are isolated in their own provisioner
  # below, which stays suppressed by design.
  kustomize_deploy_conn_private_key         = try(nonsensitive(var.ssh_private_key), var.ssh_private_key)
  kustomize_deploy_conn_agent_identity      = try(nonsensitive(local.ssh_agent_identity), local.ssh_agent_identity)
  kustomize_deploy_conn_bastion_private_key = try(nonsensitive(local.ssh_bastion.bastion_private_key), local.ssh_bastion.bastion_private_key)
}

resource "terraform_data" "kustomization_user" {
  for_each = local.user_kustomization_templates

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = local.first_control_plane_ip
    port           = var.ssh_port

    bastion_host        = local.ssh_bastion.bastion_host
    bastion_port        = local.ssh_bastion.bastion_port
    bastion_user        = local.ssh_bastion.bastion_user
    bastion_private_key = local.ssh_bastion.bastion_private_key

  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p $(dirname /var/user_kustomize/${each.key})"
    ]
  }

  provisioner "file" {
    content     = templatefile("${var.extra_kustomize_folder}/${each.key}", var.extra_kustomize_parameters)
    destination = replace("/var/user_kustomize/${each.key}", ".yaml.tpl", ".yaml")
  }

  triggers_replace = {
    manifest_sha1 = "${sha1(templatefile("${var.extra_kustomize_folder}/${each.key}", var.extra_kustomize_parameters))}"
  }

  depends_on = [
    terraform_data.kustomization
  ]
}
moved {
  from = null_resource.kustomization_user
  to   = terraform_data.kustomization_user
}

resource "terraform_data" "kustomization_user_deploy" {
  count = length(local.user_kustomization_templates) > 0 ? 1 : 0

  connection {
    user           = "root"
    private_key    = local.kustomize_deploy_conn_private_key
    agent_identity = local.kustomize_deploy_conn_agent_identity
    host           = local.first_control_plane_ip
    port           = var.ssh_port

    bastion_host        = local.ssh_bastion.bastion_host
    bastion_port        = local.ssh_bastion.bastion_port
    bastion_user        = local.ssh_bastion.bastion_user
    bastion_private_key = local.kustomize_deploy_conn_bastion_private_key

  }

  # Remove templates after rendering, and apply changes.
  # References no secrets, and the connection above is un-masked, so this provisioner's
  # output/errors are VISIBLE. `kubectl apply -k` is the last command, so a non-zero
  # exit fails the provisioner directly — a failed reconcile can no longer be masked by
  # the exit code of the trailing extra_kustomize_deployment_commands (the original bug).
  provisioner "remote-exec" {
    # Debugging: "sh -c 'for file in $(find /var/user_kustomize -type f -name \"*.yaml\" | sort -n); do echo \"\n### Template $${file}.tpl after rendering:\" && cat $${file}; done'",
    inline = [
      "rm -f /var/user_kustomize/**/*.yaml.tpl",
      "echo 'Applying user kustomization...'",
      "kubectl apply -k /var/user_kustomize/ --wait=true",
    ]
  }

  # Sensitive follow-up commands (may embed secrets, e.g. from extra_kustomize_parameters).
  # Referencing the sensitive value keeps THIS provisioner's output suppressed by tofu —
  # by design, so secrets never print. The leading "true" keeps inline non-empty when the
  # var is unset (compact() would otherwise yield an empty list).
  provisioner "remote-exec" {
    inline = compact([
      "true",
      var.extra_kustomize_deployment_commands,
    ])
  }

  lifecycle {
    replace_triggered_by = [
      terraform_data.kustomization_user
    ]
  }

  depends_on = [
    terraform_data.kustomization_user
  ]
}
moved {
  from = null_resource.kustomization_user_deploy
  to   = terraform_data.kustomization_user_deploy
}
