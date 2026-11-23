# Standalone applications (services.applications): the compose type, per-host
# expansion, and validation. Plan-only; no providers needed. Joining list
# values in `environment` happens at the root (tests/compose.tftest.hcl).

run "compose_with_hosts" {
  command = plan

  variables {
    config = {
      src = {
        type       = "compose"
        repository = "https://github.com/example/src.git"
        ref        = "main"
        profiles   = ["public", "extra"]
        ports      = ["51000-51999/udp", "443/tcp"]
        environment = {
          CHATS        = "trade"
          PEER_SOURCES = "https://github.com/a/b,https://gitlab.com/c/d#main"
          PEER_WEIGHT  = 0.5
        }
        hosts = {
          docker-1 = {
            instance_id = "mi-0000000000000000a"
            environment = { TRACKER_HOST = "59.example.org", CHATS = "lobby" }
          }
          docker-2 = {
            instance_id = "mi-0000000000000000b"
          }
        }
      }
    }
  }

  assert {
    condition     = length(output.requests) == 2
    error_message = "One request per host"
  }

  assert {
    condition     = toset([for r in output.requests : r.class]) == toset(["src-docker-1", "src-docker-2"])
    error_message = "Host requests are named <app>-<host>"
  }

  assert {
    condition = alltrue([
      for r in output.requests :
      r.type == "compose" && r.script == "compose-stack.sh" && r.teardown && r.targeting_mode == "instance"
    ])
    error_message = "compose requests run compose-stack.sh, pinned to their instance, with teardown"
  }

  assert {
    condition     = [for r in output.requests : r.instance_id if r.class == "src-docker-1"][0] == "mi-0000000000000000a"
    error_message = "Host instance_id becomes the request's instance_id"
  }

  # Environment: profiles become COMPOSE_PROFILES, and a host's values replace
  # the app's.
  assert {
    condition = tomap([for r in output.requests : r.environment if r.class == "src-docker-1"][0]) == tomap({
      CHATS            = "lobby"
      COMPOSE_PROFILES = "public,extra"
      PEER_SOURCES     = "https://github.com/a/b,https://gitlab.com/c/d#main"
      PEER_WEIGHT      = "0.5"
      TRACKER_HOST     = "59.example.org"
    })
    error_message = "docker-1 environment should be the app's, normalized, with its overrides"
  }

  assert {
    condition     = [for r in output.requests : r.environment.CHATS if r.class == "src-docker-2"][0] == "trade"
    error_message = "A host without overrides gets the app's environment"
  }

  assert {
    condition = tomap([for r in output.requests : r.params if r.class == "src-docker-2"][0]) == tomap({
      STACK_NAME       = "src"
      STACK_REPOSITORY = "https://github.com/example/src.git"
      STACK_REF        = "main"
      STACK_PATH       = "."
      STACK_DIRECTORY  = "/opt/stacks/src"
      STACK_PORTS      = "51000-51999/udp 443/tcp"
    })
    error_message = "Stack settings become compose-stack.sh parameters (named after the app, not the host)"
  }

  assert {
    condition     = endswith([for r in output.requests : r.script_source_path][0], "applications/scripts/compose-stack.sh")
    error_message = "compose requests are enriched with the script path"
  }
}

run "compose_defaults_and_tag_targeting" {
  command = plan

  variables {
    config = {
      stack = {
        type       = "compose"
        repository = "https://gitlab.com/example/stack.git"
        path       = "deploy"
        targeting = {
          mode = "tags"
          tags = { Class = ["oci-ubuntu"] }
        }
      }
    }
  }

  assert {
    condition     = output.requests[0].class == "stack" && output.requests[0].instance_id == null
    error_message = "Without hosts, one request named after the app"
  }

  assert {
    condition     = output.requests[0].targeting_mode == "tags" && output.requests[0].targets[0].key == "tag:Class"
    error_message = "Tag targeting passes through"
  }

  assert {
    condition = (
      output.requests[0].params.STACK_REF == "HEAD" &&
      output.requests[0].params.STACK_PATH == "deploy" &&
      output.requests[0].params.STACK_PORTS == "" &&
      length(output.requests[0].environment) == 0
    )
    error_message = "Defaults: remote default branch, no ports, empty environment"
  }
}

run "ssm_script_with_environment" {
  command = plan

  variables {
    config = {
      agent = {
        type        = "ssm"
        script      = "install-redis.sh"
        params      = { PORT = 6379 }
        environment = { MODE = "replica" }
      }
    }
  }

  assert {
    condition = (
      output.requests[0].script == "install-redis.sh" &&
      tomap(output.requests[0].params) == tomap({ PORT = "6379" }) &&
      tomap(output.requests[0].environment) == tomap({ MODE = "replica" }) &&
      output.requests[0].teardown == false &&
      output.requests[0].targeting_mode == "wildcard"
    )
    error_message = "ssm apps keep their script and params, get their environment, no teardown"
  }
}

run "compose_requires_repository" {
  command = plan

  variables {
    config = {
      broken = { type = "compose" }
    }
  }

  expect_failures = [var.config]
}

run "compose_name_must_be_a_project_name" {
  command = plan

  variables {
    config = {
      "My Stack" = { type = "compose", repository = "https://github.com/example/x.git" }
    }
  }

  expect_failures = [var.config]
}

run "ports_are_validated" {
  command = plan

  variables {
    config = {
      stack = { type = "compose", repository = "https://github.com/example/x.git", ports = ["51000:51999"] }
    }
  }

  expect_failures = [var.config]
}

# A host without instance_id is a type error (instance_id is required).
run "hosts_only_for_script_types" {
  command = plan

  variables {
    config = {
      playbook = {
        type     = "ansible"
        playbook = "docker"
        hosts    = { docker-1 = { instance_id = "mi-0000000000000000a" } }
      }
    }
  }

  expect_failures = [var.config]
}

run "unknown_type_rejected" {
  command = plan

  variables {
    config = {
      thing = { type = "kubernetes" }
    }
  }

  expect_failures = [var.config]
}
