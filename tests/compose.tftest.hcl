# Root wiring for compose applications: a fragment's environment (lists,
# numbers, bools) reaches the applications module as strings, and each host
# becomes an SSM document + association pinned to its instance, with no EC2
# instance role and no scripts bucket.

variables {
  workspace_overrides = false
  aws_profile         = "example-platform-dev"
  fragments           = ["compose-stack"]
}

run "compose_stack_per_host" {
  command = plan

  assert {
    condition = tomap(module.applications[0].requests[0].environment) == tomap({
      CHATS            = "trade"
      COMPOSE_PROFILES = "public"
      DEBUG            = "true"
      EMPTY            = ""
      HOST_NAME        = "one.example.org"
      SOURCES          = "https://github.com/e/f"
      WEIGHT           = "0.5"
    })
    error_message = "Host one: lists joined, scalars stringified, host values win"
  }

  assert {
    condition     = module.applications[0].requests[1].environment.SOURCES == "https://github.com/a/b,https://gitlab.com/c/d#main"
    error_message = "Host two: the app's list joined with commas"
  }

  assert {
    condition     = toset(keys(module.configuration_management[0].application_associations)) == toset(["demo-one", "demo-two"])
    error_message = "One association per host"
  }

  assert {
    condition     = jsonencode(module.configuration_management[0].application_associations["demo-two"].targets) == jsonencode([{ key = "InstanceIds", values = ["mi-0000000000000000b"] }])
    error_message = "Each association targets its host's instance"
  }

  assert {
    condition     = !contains(keys(module.access.iam_role_names), "compute-instance")
    error_message = "Host-pinned applications need no compute instance role"
  }

  assert {
    condition     = !contains(keys(module.storage[0].bucket_names), "application-scripts")
    error_message = "compose applications need no scripts bucket"
  }
}
