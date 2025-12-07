# Auto-documentation module
# Generates SCHEMA.md from variables.tf files across all modules
# Updates Architecture and Available Services sections in README.md
# The scripts write files directly, so they persist after terraform destroy

data "external" "generate_docs" {
  program = ["python3", "${path.module}/scripts/generate_docs.py"]

  query = {
    project_root = var.project_root
    output_file  = var.output_file
  }
}

data "external" "update_readme" {
  program = ["python3", "${path.module}/scripts/update_readme.py"]

  query = {
    project_root = var.project_root
    readme_file  = var.readme_file
  }
}
