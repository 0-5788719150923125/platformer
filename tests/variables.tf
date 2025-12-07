variable "run_all_module_tests" {
  type        = bool
  default     = false
  description = "When enabled, runs all module-level test suites via local-exec provisioner"
}
