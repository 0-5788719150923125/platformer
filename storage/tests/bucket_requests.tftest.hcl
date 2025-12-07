# Test dependency inversion pattern for storage module

variables {
  aws_account_id = "123456789012"
}

# Test 1: Basic bucket creation with dependency inversion pattern
run "bucket_requests_basic" {
  command = plan

  variables {
    namespace = "test-namespace"

    bucket_requests = [
      {
        purpose     = "test-logs"
        description = "Test logging bucket"
      }
    ]
  }

  # Verify bucket is created with correct name
  assert {
    condition     = aws_s3_bucket.requested["test-logs"].bucket == "test-logs-test-namespace"
    error_message = "Bucket name should follow purpose-namespace pattern"
  }

  # Verify force_destroy is enabled by default
  assert {
    condition     = aws_s3_bucket.requested["test-logs"].force_destroy == true
    error_message = "force_destroy should be enabled by default"
  }

  # Verify encryption is enabled
  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.requested) == 1
    error_message = "Server-side encryption should be enabled"
  }

  # Verify public access is blocked by default
  assert {
    condition     = aws_s3_bucket_public_access_block.requested["test-logs"].block_public_acls == true
    error_message = "Public access should be blocked by default"
  }
}

# Test 2: Bucket with prefix naming
run "bucket_requests_with_prefix" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose     = "ssm-association-logs"
        description = "SSM logs"
        prefix      = "ssm-logs"
      }
    ]
  }

  # Verify prefix is included in bucket name
  assert {
    condition     = aws_s3_bucket.requested["ssm-association-logs"].bucket == "ssm-logs-ssm-association-logs-test"
    error_message = "Bucket name should include prefix"
  }
}

# Test 3: Versioning enabled
run "bucket_requests_with_versioning" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose            = "versioned-bucket"
        description        = "Bucket with versioning"
        versioning_enabled = true
      }
    ]
  }

  # Verify versioning resource is created
  assert {
    condition     = length(aws_s3_bucket_versioning.requested) == 1
    error_message = "Versioning should be enabled for requested bucket"
  }

  # Verify versioning is enabled
  assert {
    condition     = aws_s3_bucket_versioning.requested["versioned-bucket"].versioning_configuration[0].status == "Enabled"
    error_message = "Versioning status should be Enabled"
  }
}

# Test 4: Access logging
run "bucket_requests_with_access_logging" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose        = "logged-bucket"
        description    = "Bucket with access logging"
        access_logging = true
      }
    ]
  }

  # Verify access logs bucket is created
  assert {
    condition     = length(aws_s3_bucket.access_logs) == 1
    error_message = "Access logs bucket should be created when access_logging=true"
  }

  # Verify access logs bucket name
  assert {
    condition     = aws_s3_bucket.access_logs[0].bucket == "access-logs-test"
    error_message = "Access logs bucket should follow naming convention"
  }

  # Verify logging configuration is created
  assert {
    condition     = length(aws_s3_bucket_logging.requested) == 1
    error_message = "Bucket logging configuration should be created"
  }

  # Verify bucket policy for log delivery
  assert {
    condition     = length(aws_s3_bucket_policy.access_logs) == 1
    error_message = "Access logs bucket policy should be created"
  }
}

# Test 5: Access logging disabled (opt-out)
run "bucket_requests_without_access_logging" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose        = "no-logs-bucket"
        description    = "Bucket without access logging"
        access_logging = false
      }
    ]
  }

  # Verify access logs bucket is NOT created
  assert {
    condition     = length(aws_s3_bucket.access_logs) == 0
    error_message = "Access logs bucket should not be created when access_logging=false"
  }
}

# Test 6: Lifecycle configuration with Intelligent-Tiering
run "bucket_requests_with_intelligent_tiering" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose             = "tiered-bucket"
        description         = "Bucket with Intelligent-Tiering"
        intelligent_tiering = true
      }
    ]
  }

  # Verify lifecycle configuration is created
  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.requested) == 1
    error_message = "Lifecycle configuration should be created for Intelligent-Tiering"
  }
}

# Test 7: Lifecycle configuration with Standard-IA transition
run "bucket_requests_with_lifecycle" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose        = "lifecycle-bucket"
        description    = "Bucket with lifecycle rules"
        lifecycle_days = 90
        glacier_days   = 180
      }
    ]
  }

  # Verify lifecycle configuration is created
  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.requested) == 1
    error_message = "Lifecycle configuration should be created"
  }
}

# Test 8: Multiple buckets
run "bucket_requests_multiple" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose     = "bucket-one"
        description = "First bucket"
      },
      {
        purpose     = "bucket-two"
        description = "Second bucket"
      },
      {
        purpose     = "bucket-three"
        description = "Third bucket"
      }
    ]
  }

  # Verify all buckets are created
  assert {
    condition     = length(aws_s3_bucket.requested) == 3
    error_message = "All requested buckets should be created"
  }
}

# Test 9: CORS enabled
run "bucket_requests_with_cors" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose      = "cors-bucket"
        description  = "Bucket with CORS"
        cors_enabled = true
      }
    ]
  }

  # Verify CORS configuration is created
  assert {
    condition     = length(aws_s3_bucket_cors_configuration.requested) == 1
    error_message = "CORS configuration should be created"
  }
}

# Test 10: Public access enabled (opt-in)
run "bucket_requests_public_access" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      {
        purpose       = "public-bucket"
        description   = "Public bucket"
        public_access = true
      }
    ]
  }

  # Verify public access is NOT blocked
  assert {
    condition     = aws_s3_bucket_public_access_block.requested["public-bucket"].block_public_acls == false
    error_message = "Public access should not be blocked when public_access=true"
  }
}

# Test 11: Unique purpose validation (should fail)
run "unique_purpose_validation" {
  command = plan

  variables {
    namespace = "test"

    bucket_requests = [
      { purpose = "logs", description = "Logs 1" },
      { purpose = "logs", description = "Logs 2" } # Duplicate purpose
    ]
  }

  expect_failures = [
    var.bucket_requests
  ]
}

# Test 12: Empty bucket_requests (no buckets created)
run "bucket_requests_empty" {
  command = plan

  variables {
    namespace       = "test"
    bucket_requests = []
  }

  # Verify no buckets are created
  assert {
    condition     = length(aws_s3_bucket.requested) == 0
    error_message = "No buckets should be created when bucket_requests is empty"
  }

  # Verify no access logs bucket
  assert {
    condition     = length(aws_s3_bucket.access_logs) == 0
    error_message = "Access logs bucket should not be created when no buckets request logging"
  }
}
