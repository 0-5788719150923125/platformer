## Password Rotation Flow

This diagram shows how instances self-manage their password rotations within the same AWS account. Our orchestrator deploys the SSM State Manager association, which triggers instances to execute password rotation scripts on themselves every 30 minutes. Each instance then saves its new password directly to Parameter Store in the same account. No cross-account secrets management required.

```mermaid
flowchart LR
    subgraph Deploy["Terraform Orchestrator"]
        TF[main.tf]
    end

    subgraph Account["AWS Account"]
        direction LR
        SSM[SSM State Manager<br/>Associations]

        subgraph Instances["EC2 Instances"]
            I1[Instance 1]
            I2[Instance 2]
        end

        subgraph ParamStore["Parameter Store"]
            P1[i-xxx/administrator]
            P2[i-yyy/administrator]
        end

        I1 -->|"check-in: every 30 min"| SSM
        SSM -->|"execute rotation"| I1
        I1 -->|"save password"| P1

        I2 -->|"check-in: every 3 hours"| SSM
        SSM -->|"execute rotation"| I2
        I2 -->|"save password"| P2
    end

    TF -.->|"deploy automation"| SSM

    classDef orchestratorStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef automationStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000
    classDef instanceStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef secretStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000

    class TF orchestratorStyle
    class SSM automationStyle
    class I1,I2 instanceStyle
    class P1,P2 secretStyle
```

---

### Self-Managed Infrastructure:

Instances execute rotation scripts on themselves and save passwords locally to Parameter Store - all within the same AWS account. Terraform manages the complete lifecycle: deploy association, rotate passwords, destroy cleanly.
