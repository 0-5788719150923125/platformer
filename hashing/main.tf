# Generate a stable random seed (only created once, persists in state)
# Used by algorithms that require deterministic seeding
resource "random_id" "seed" {
  count       = var.algorithm != "pet" && var.seed == "" ? 1 : 0
  byte_length = 8
}

# Random pet namespace (traditional approach)
resource "random_pet" "namespace" {
  count  = var.algorithm == "pet" ? 1 : 0
  length = var.length
}

# Determine the seed to use: provided seed or generated stable seed
locals {
  seed_value = var.seed != "" ? var.seed : (length(random_id.seed) > 0 ? random_id.seed[0].hex : "")
}

# Execute algorithm-specific generator
# Calls scripts/get-{algorithm}.sh for extensibility
data "external" "generated_name" {
  count = var.algorithm != "pet" ? 1 : 0

  program = [
    "bash",
    "-c",
    "name=$(${path.module}/scripts/get-${var.algorithm}.sh '${local.seed_value}'); echo \"{\\\"name\\\": \\\"$name\\\"}\""
  ]
}

# Output namespace based on selected algorithm
locals {
  namespace = var.algorithm == "pet" ? random_pet.namespace[0].id : data.external.generated_name[0].result.name
}
