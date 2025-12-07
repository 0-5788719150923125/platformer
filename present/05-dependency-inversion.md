## Innovation: Dependency Inversion

This diagram shows a single example of dependency inversion in action. Follow the numbered steps: configuration-management declares it needs a bucket, main.tf detects this need and auto-enables storage, storage creates the bucket, and finally the bucket name loops back to configuration-management. Notice that configuration-management never directly references the storage module.

```mermaid
flowchart LR
    CM[Configuration<br/>Management]
    Main[main.tf]
    Storage[Storage]
    Bucket[S3 Bucket<br/>Created]

    CM -->|"① I need a bucket"| Main
    Main -->|"② auto-enable"| Storage
    Storage -->|"③ create"| Bucket
    Bucket -.->|"④ bucket name"| Main
    Main -.->|"⑤ here's your bucket"| CM

    classDef consumerStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef orchestratorStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef providerStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef resourceStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000

    class CM consumerStyle
    class Main orchestratorStyle
    class Storage providerStyle
    class Bucket resourceStyle
```

---

### Key Benefit:

**Traditional Approach:**
- configuration-management must know about storage module
- Tight coupling between modules
- Hard to test in isolation

**Inverted Dependencies:**
- configuration-management declares "I need a bucket"
- main.tf detects need and enables storage automatically
- Modules remain decoupled and testable
- No explicit `storage: {}` configuration required

**Further Reading:**

This pattern extends dependency injection principles to Terraform module composition. Rather than modules instantiating their dependencies directly, they declare needs through interfaces, and the orchestrator injects providers automatically.

https://en.wikipedia.org/wiki/Dependency_injection

https://developer.hashicorp.com/platformer/language/modules/develop/composition
