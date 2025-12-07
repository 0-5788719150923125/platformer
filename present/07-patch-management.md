## Patch Management Flow

This diagram shows how patch management works similarly to password rotation, with instances checking in on their maintenance window schedules. The patch baseline defines which patches are approved, the maintenance window controls when instances check in, and SSM orchestrates the patching process. Notice how different instance classes can have different schedules.

```mermaid
flowchart LR
    subgraph Deploy["Terraform Orchestrator"]
        TF[main.tf]
    end

    subgraph Account["AWS Account"]
        direction LR

        subgraph Config["Configuration"]
            PB[Patch Baseline<br/>windows-catchall]
            MW[Maintenance Window<br/>Schedules]
        end

        SSM[SSM Patch Manager]

        subgraph Instances["EC2 Instances"]
            I1[windows-poc-1]
            I2[windows-poc-2]
        end

        PB --> SSM
        MW --> SSM

        I1 -->|"check-in: every 3 hours"| SSM
        SSM -->|"run patch baseline"| I1
        I1 -->|"install + reboot"| I1

        I2 -->|"check-in: monthly"| SSM
        SSM -->|"run patch baseline"| I2
        I2 -->|"install + reboot"| I2
    end

    TF -.->|"deploy automation"| Config

    classDef orchestratorStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef configStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000
    classDef automationStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef instanceStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000

    class TF orchestratorStyle
    class PB,MW configStyle
    class SSM automationStyle
    class I1,I2 instanceStyle
```

---

### Class-Based Targeting:

Namespace isolation ensures multi-developer and multi-environment deployments don't cross-contaminate in shared AWS accounts. Each instance class can have different patch schedules and baselines.

### Pattern-Based Targeting:

Maintenance windows and patch baselines support wildcard and pattern-matched targeting for managing instances outside of Terraform's control. Use patterns like `*-windows-*` to match multiple classes, or `*` to target all instances in an account. This enables patch management of existing infrastructure that wasn't deployed by this framework, without requiring explicit enumeration of instance classes.
