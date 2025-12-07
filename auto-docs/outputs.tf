# Auto-docs outputs

output "schema_file_path" {
  description = "Path to generated schema file"
  value       = "${path.module}/${var.project_root}/${var.output_file}"
}

output "modules_documented" {
  description = "Number of modules documented"
  value       = tonumber(data.external.generate_docs.result.module_count)
}

output "content_hash" {
  description = "MD5 hash of generated content (for change detection)"
  value       = data.external.generate_docs.result.content_hash
}

output "readme_updated" {
  description = "Status of README update"
  value       = data.external.update_readme.result.status
}

output "readme_hash" {
  description = "MD5 hash of updated README (for change detection)"
  value       = data.external.update_readme.result.content_hash
}
