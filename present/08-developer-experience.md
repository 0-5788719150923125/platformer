## Developer Experience

This diagram shows two deployment paths that use the same configuration approach. A developer on their laptop deploys to a single account/region for testing, while CI/CD reads top.yaml to generate a matrix and deploys to multiple accounts simultaneously. Both use identical state fragments - the only difference is the deployment scope.

```mermaid
flowchart LR
    subgraph Entrypoints["Deployment Sources"]
        Dev[Developer Laptop]
        CI[CI/CD Pipeline]
    end

    subgraph Config["Unified Configuration"]
        States["State Fragments<br/>terraform.tfvars"]
    end

    subgraph Targets["AWS Accounts"]
        direction TB
        DevAccount[Account: example-platform-dev<br/>Region: us-east-2]

        subgraph Matrix["CI Matrix Deployments"]
            Acc1[Account: archpacs-dev<br/>Region: us-east-2]
            Acc2[Account: archpacs-uat<br/>Region: us-east-1]
            Acc3[Account: archpacs-prod<br/>Region: us-east-1]
        end
    end

    Dev -->|"load states from terraform.tfvars"| States
    CI -->|"load states from top.yaml"| States

    States -->|"single deploy"| DevAccount
    States -.->|"parallel matrix"| Acc1
    States -.->|"parallel matrix"| Acc2
    States -.->|"parallel matrix"| Acc3

    classDef devStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef ciStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef configStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000
    classDef accountStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000

    class Dev devStyle
    class CI ciStyle
    class States configStyle
    class DevAccount,Acc1,Acc2,Acc3 accountStyle
```

---

### Dev/Prod Parity:

Same code, same state fragments - developers test locally with a single account, CI/CD deploys to multiple accounts via matrix. The configuration approach is unified regardless of deployment source.
