## Developer Experience

This diagram shows two deployment paths that use the same configuration approach. A developer on their laptop deploys to a single account/region for testing, while CI/CD reads top.yaml to generate a matrix and deploys to multiple accounts simultaneously. Both use identical fragments - the only difference is the deployment scope.

```mermaid
flowchart LR
    subgraph Entrypoints["Deployment Sources"]
        Dev[Developer Laptop]
        CI[CI/CD Pipeline]
    end

    subgraph Config["Unified Configuration"]
        Fragments["Fragments<br/>terraform.tfvars"]
    end

    subgraph Targets["AWS Accounts"]
        direction TB
        DevAccount[Account: example-platform-dev<br/>Region: us-east-2]

        subgraph Matrix["CI Matrix Deployments"]
            Acc1[Account: iopacs-dev<br/>Region: us-east-2]
            Acc2[Account: iopacs-uat<br/>Region: us-east-1]
            Acc3[Account: iopacs-prod<br/>Region: us-east-1]
        end
    end

    Dev -->|"load fragments from terraform.tfvars"| Fragments
    CI -->|"load fragments from top.yaml"| Fragments

    Fragments -->|"single deploy"| DevAccount
    Fragments -.->|"parallel matrix"| Acc1
    Fragments -.->|"parallel matrix"| Acc2
    Fragments -.->|"parallel matrix"| Acc3

    classDef devStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef ciStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000
    classDef configStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#000
    classDef accountStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000

    class Dev devStyle
    class CI ciStyle
    class Fragments configStyle
    class DevAccount,Acc1,Acc2,Acc3 accountStyle
```

---

### Dev/Prod Parity:

Same code, same fragments - developers test locally with a single account, CI/CD deploys to multiple accounts via matrix. The configuration approach is unified regardless of deployment source.
