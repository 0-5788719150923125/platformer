## The Problem: Fragmented State

The legacy approach uses separate directory structures and state files for each environment. This diagram illustrates the chaos that results: developers working independently with no coordination, Atlantis attempting to orchestrate across fragmented states, and each environment having only partial visibility into other accounts. Notice the abundance of dotted lines showing uncertainty and manual coordination efforts.

```mermaid
graph TB
    subgraph "Directory Sprawl"
        EnvDev[environment/dev/<br/>state file]
        EnvStaging[environment/staging/<br/>state file]
        EnvProd[environment/prod/<br/>state file]
        EnvUAT[environment/uat/<br/>state file]
    end

    subgraph "AWS Accounts"
        DevAcct[Dev Account<br/>partial resources]
        StagingAcct[Staging Account<br/>partial resources]
        ProdAcct[Prod Account<br/>partial resources]
        UATAcct[UAT Account<br/>partial resources]
    end

    subgraph "Manual Coordination"
        Atlantis[Atlantis<br/>orchestration tool]
        Dev1[Developer A<br/>changes dev]
        Dev2[Developer B<br/>changes staging]
        Dev3[Developer C<br/>changes prod]
    end

    EnvDev -.->|partial visibility| DevAcct
    EnvStaging -.->|partial visibility| StagingAcct
    EnvProd -.->|partial visibility| ProdAcct
    EnvUAT -.->|partial visibility| UATAcct

    Atlantis -.->|tries to coordinate| EnvDev
    Atlantis -.->|tries to coordinate| EnvStaging
    Atlantis -.->|tries to coordinate| EnvProd
    Atlantis -.->|tries to coordinate| EnvUAT

    Dev1 -.->|manual sync| EnvDev
    Dev1 -.->|copy config?| EnvStaging
    Dev2 -.->|different config?| EnvStaging
    Dev2 -.->|drift| EnvProd
    Dev3 -.->|manual updates| EnvProd
    Dev3 -.->|forgot UAT?| EnvUAT

    EnvDev -.->|can't see| ProdAcct
    EnvProd -.->|can't see| DevAcct
    EnvStaging -.->|no pattern matching| UATAcct

    classDef problemStyle fill:#ffcccc,stroke:#c62828,stroke-width:2px,color:#000
    classDef orchestrateStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef devStyle fill:#e0e0e0,stroke:#424242,stroke-width:2px,color:#000

    class EnvDev,EnvStaging,EnvProd,EnvUAT problemStyle
    class DevAcct,StagingAcct,ProdAcct,UATAcct problemStyle
    class Atlantis orchestrateStyle
    class Dev1,Dev2,Dev3 devStyle
```

---

### The Legacy Approach Creates Multiple Pain Points:

- Each State File Operates in Isolation - No Organizational Context
- Manual Coordination Across Environments Leads to Drift
- No Pattern Matching - Explicit Management of Every Environment
- Orchestration Tools Needed Just to Keep Things Synchronized
