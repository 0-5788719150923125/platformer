## The Solution: One State

This diagram shows how a single codebase with pattern matching replaces the fragmented approach. Pattern expressions like `*-platform-dev` automatically match multiple accounts discovered via the AWS Organizations API. Every deployment converges toward the same state—one unified configuration manifest where services are conditionally enabled based on composed state fragments. The deployment matrix generates parallel executions across matched accounts and regions, eliminating the need for manual coordination.

```mermaid
graph TB
    subgraph "Single Source of Truth"
        TF[platformer/<br/>main.tf + modules]
        Top[top.yaml<br/>pattern matching]
    end

    subgraph "Pattern-Based Targeting"
        P1["*-platform-dev"]
        P2["*uat* or *staging*"]
        P3["archpacs-*"]
    end

    subgraph "AWS Organization"
        Org[Organizations API<br/>auto-discover accounts]
        D1[Dev Accounts]
        D2[Staging Accounts]
        D3[Prod Accounts]
        D4[UAT Accounts]
    end

    subgraph "Deployment Matrix"
        M[Account × Region<br/>parallel execution]
    end

    TF --> Top
    Top --> P1
    Top --> P2
    Top --> P3

    P1 -.->|matches| D1
    P2 -.->|matches| D2
    P2 -.->|matches| D4
    P3 -.->|matches| D1
    P3 -.->|matches| D3

    Org --> D1
    Org --> D2
    Org --> D3
    Org --> D4

    D1 --> M
    D2 --> M
    D3 --> M
    D4 --> M

    classDef goodStyle fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef patternStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#000
    classDef awsStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#000

    class TF,Top,Org goodStyle
    class P1,P2,P3 patternStyle
    class D1,D2,D3,D4,M awsStyle
```

---

### How It Solves the Problems:

- **One Codebase:** Single state per account/region - no directory sprawl
- **Pattern Matching:** `*-platform-dev` targets all platform dev accounts automatically
- **Full Visibility:** Every deployment knows about the entire organization via AWS Organizations API
- **No Manual Coordination:** GitHub Actions generates deployment matrix automatically
