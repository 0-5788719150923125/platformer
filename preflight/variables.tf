variable "required_tools" {
  description = "Map of tool checks with check type and commands to verify"
  type = map(object({
    type     = string       # "discrete" (single tool) or "any" (any tool from list)
    commands = list(string) # For discrete: single command. For any: alternatives to try
  }))
  default = {}
}
