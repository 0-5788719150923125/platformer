# Shared assets (scripts, templates, hooks) stay in the service directory, one
# level up. When the root calls this adapter, path.module is "<service>/aws" and
# dirname() gives "<service>": the same paths as before the split, so nothing
# that records them (e.g. S3 object sources) changes. When the adapter's tests
# run it directly, path.module is "." and the service directory is "..".
locals {
  service_path = path.module == "." ? ".." : dirname(path.module)
}
