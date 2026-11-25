# Aurora cluster requests (storage/rds.tf). The cluster and its instances are
# declared directly (they used to come from terraform-aws-modules/rds-aurora);
# these runs pin the behavior the module provided.

variables {
  aws_account_id = "123456789012"
  namespace      = "test-namespace"
}

run "aurora_cluster_with_instances" {
  command = plan

  variables {
    rds_cluster_requests = [
      {
        purpose        = "catalog"
        type           = "aurora"
        name           = "catalog-db"
        database_name  = "catalog"
        engine_version = "16.4"
        instance_class = "db.t4g.medium"
        vpc_id         = "vpc-12345678"
        subnet_ids     = ["subnet-aaaa1111", "subnet-bbbb2222"]
        instances      = 2
        final_snapshot = false
      }
    ]
  }

  assert {
    condition     = aws_rds_cluster.requested["catalog"].cluster_identifier == "catalog-db"
    error_message = "The cluster identifier should be the requested name"
  }
  assert {
    condition     = aws_rds_cluster.requested["catalog"].engine == "aurora-postgresql" && aws_rds_cluster.requested["catalog"].storage_encrypted == true
    error_message = "Clusters are encrypted aurora-postgresql, as the module created them"
  }
  assert {
    condition     = aws_rds_cluster.requested["catalog"].master_username == "catalog" && aws_rds_cluster.requested["catalog"].database_name == "catalog"
    error_message = "The master username is the database name"
  }
  assert {
    condition     = aws_rds_cluster.requested["catalog"].skip_final_snapshot == true
    error_message = "final_snapshot = false should skip the final snapshot"
  }
  assert {
    condition     = toset(keys(aws_rds_cluster_instance.requested)) == toset(["catalog-1", "catalog-2"])
    error_message = "One instance per count, keyed <purpose>-<n> from 1"
  }
  assert {
    condition     = aws_rds_cluster_instance.requested["catalog-2"].identifier == "catalog-db-2" && aws_rds_cluster_instance.requested["catalog-2"].instance_class == "db.t4g.medium"
    error_message = "Instances are named <name>-<n> and use the requested class"
  }
  assert {
    condition     = aws_rds_cluster_instance.requested["catalog-1"].auto_minor_version_upgrade == false
    error_message = "Minor version upgrades stay manual"
  }
}

run "no_aurora_requests" {
  command = plan

  assert {
    condition     = length(aws_rds_cluster.requested) == 0 && length(aws_rds_cluster_instance.requested) == 0
    error_message = "Without requests there are no clusters or instances"
  }
}
