# Storage

Centralized S3 bucket provisioning using dependency inversion. Modules declare their storage needs, the storage module creates and manages the resources.

## Concept

Instead of modules creating their own buckets, they output requests describing what they need. The storage module collects all requests and provisions buckets with standardized security controls. This ensures consistent encryption, logging, lifecycle policies, and naming conventions across all storage resources.

The module auto-enables when any service requests storage, requiring no explicit configuration.

## Key Features

- **Dependency Inversion** - Consumers declare needs, storage fulfills them
- **Automatic Activation** - No manual toggling required
- **Security by Default** - All buckets encrypted, logged, and lifecycle-managed
- **Namespace Isolation** - Bucket names scoped to deployment namespace
- **RDS/ElastiCache Support** - Also handles database and cache provisioning

## Design Benefits

1. **Consistency** - All storage follows the same security patterns
2. **Discoverability** - Single place to audit all storage resources
3. **Lifecycle Management** - Buckets destroyed cleanly with Terraform
4. **Multi-tenant Safe** - Namespace prefixing prevents collisions
