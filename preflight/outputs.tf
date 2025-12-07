output "results" {
  description = "Map of tool names to availability status (true/false strings)"
  value       = data.external.check_tools.result
}
