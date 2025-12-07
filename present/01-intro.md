## Platformer

**Self-Service Infrastructure Framework**

This diagram shows how Platformer orchestrates infrastructure from state fragments through to AWS deployment. Configuration flows through a config module, an orchestration layer makes conditional decisions about which modules to enable, and service modules are rendered into AWS infrastructure deployments.

```mermaid
graph LR
    TFVars["terraform.tfvars<br/>states = (...)"]

    subgraph Config["Configuration Resolution"]
        direction TB
        States[State Fragments<br/>YAML files]
        ConfigMod[Config Module<br/>Load & Deep Merge]
        States --> ConfigMod
    end

    subgraph Orchestrate["Orchestration Layer"]
        MainTF[main.tf<br/>Auto-Enable Logic]
    end

    subgraph Services["Service Modules"]
        direction TB
        ConfigMgmt[configuration-management]
        Compute[compute]
        Storage[storage]
        Legacy[legacy]
    end

    AWS[AWS Infrastructure<br/>Multi-Account/Region]

    TFVars --> States
    ConfigMod -->|service_configs| MainTF
    MainTF -->|conditional| ConfigMgmt
    MainTF -->|conditional| Compute
    MainTF -->|auto-enable| Storage
    MainTF -->|conditional| Legacy

    ConfigMgmt --> AWS
    Compute --> AWS
    Storage --> AWS
    Legacy --> AWS

    classDef configStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef orchestrateStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef serviceStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000
    classDef awsStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:3px,color:#000

    class States,ConfigMod configStyle
    class MainTF orchestrateStyle
    class ConfigMgmt,Compute,Storage,Legacy serviceStyle
    class AWS awsStyle
```

---

### GitOps-Based Account-Level Infrastructure Management for AWS

Key Characteristics of This Framework:

- State Fragments → Config Module → Orchestration → Services → AWS
- Dependency Inversion: Modules Auto-Enable When Needed
- Pattern-Based Multi-Account Targeting via `top.yaml`
