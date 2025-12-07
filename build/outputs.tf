# Built AMI IDs (consumed by compute module for instance launches)
output "built_amis" {
  description = "Map of class name to golden AMI ID built by Packer"
  value = {
    for class_name, ami in data.aws_ami.packer_built :
    class_name => ami.id
  }
}

# Artifact registry entries for golden images (consumed by portal module)
output "artifact_requests" {
  description = "Artifact registry entries for built golden AMIs (dependency inversion to portal)."
  value = [
    for class_name, ami in data.aws_ami.packer_built : {
      name       = class_name
      version    = local.build_recipe_hash[class_name]
      type       = "golden-image"
      path       = ami.id
      source     = "build"
      created_at = ami.creation_date
      url        = "https://${data.aws_region.current.id}.console.aws.amazon.com/ec2/home?region=${data.aws_region.current.id}#ImageDetails:imageId=${ami.id}"
    }
  ]
}

# Access requests (dependency inversion interface for access module)
output "access_requests" {
  description = "IAM access requests for the access module (access creates resources, returns ARNs)"
  value       = local.access_requests
}

# Command Registry
output "commands" {
  description = "Packer build commands for CLI display and portal actions"
  value = [
    for class_name, template in local_file.packer_template : {
      title       = "Trigger Packer Build: ${class_name}"
      description = "Start a new Packer build for ${class_name} golden AMI"
      commands    = ["cd ${path.root} && packer build -force -var namespace=${var.namespace} ${template.filename}"]
      service     = "compute"
      category    = "packer-build-trigger"
      target_type = "build"
      target      = class_name
      execution   = "local-exec"
      action_config = {
        type          = "packer_build"
        template_path = template.filename
        region        = data.aws_region.current.id
      }
    }
  ]
}
