# The AWS implementation moved into build/aws/ (2026-11-25). These blocks carry
# existing state to the new addresses, so nothing is destroyed or recreated.
# Data sources need no moves; they are simply read again.

moved {
  from = local_file.packer_template
  to   = module.aws.local_file.packer_template
}

moved {
  from = null_resource.ansible_venv
  to   = module.aws.null_resource.ansible_venv
}

moved {
  from = null_resource.build_upload_archives
  to   = module.aws.null_resource.build_upload_archives
}

moved {
  from = null_resource.packer_build
  to   = module.aws.null_resource.packer_build
}

moved {
  from = module.preflight
  to   = module.aws.module.preflight
}
