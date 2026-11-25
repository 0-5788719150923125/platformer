output "instances" {
  description = "OCI instances, keyed <tenant>-<class>-<idx>"
  value = {
    for key, instance in oci_core_instance.this : key => {
      id           = instance.id
      display_name = instance.display_name
      shape        = instance.shape
      public_ip    = instance.public_ip
      private_ip   = instance.private_ip
      tenant       = var.config[key].tenant
      class        = var.config[key].class
      adopted      = var.config[key].adopt_id != null
    }
  }
}
