# Private Kafka → Fabric Real-Time Intelligence

Two independent, production-ready streaming architectures for ingesting events from a **private-network Apache Kafka cluster** into **Microsoft Fabric Real-Time Intelligence** (Eventhouse / KQL Database).

Each solution is self-contained with its own infrastructure (Bicep), Kafka configuration, event generator, and Fabric setup guide.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Solution A — "Event Hub Bridge"                                             │
│                                                                             │
│  Event Generator → Kafka (KRaft) → Kafka Connect ──→ Event Hub ──→ Fabric  │
│       (VM)           (VM)         (SASL_OAUTHBEARER)  (Private EP)   RTI    │
│                                                                             │
│  Security: OAuth 2.0 / Entra ID / Managed Identity (zero-secret)           │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ Solution B — "Direct Kafka Ingestion"                                       │
│                                                                             │
│  Event Generator → Kafka (KRaft) ──────────────────────────→ Fabric RTI    │
│       (VM)           (VM, SSL)    (Eventstream Kafka source     Eventhouse  │
│                                    + Streaming vNet Gateway)                │
│                                                                             │
│  Security: mTLS / Custom CA certificates (mutual authentication)           │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Solution Comparison

### Solution A — "Event Hub Bridge"

Kafka → Kafka Connect (OAuth) → Azure Event Hub → Fabric Eventstream → KQL DB

| Pros | Cons |
|------|------|
| **Zero-secret auth** — Managed Identity + OAuth eliminates stored credentials | Extra hop adds latency (Kafka → EH → Eventstream) |
| **Decoupled** — Event Hub acts as a buffer; Kafka and Fabric evolve independently | More moving parts (Kafka Connect, Event Hub, Private Endpoint) |
| **Proven pattern** — Event Hub Kafka protocol is battle-tested (GA since 2018) | Higher Azure cost (Event Hub TUs + Kafka Connect process) |
| **Multi-consumer** — Event Hub serves other consumers (Stream Analytics, Functions) alongside Fabric | Kafka Connect requires operational management |
| **Entra ID native** — Integrates with Azure RBAC, audit logs, conditional access | mTLS not possible on the Event Hub segment |

### Solution B — "Direct Kafka Ingestion"

Kafka (mTLS) → Fabric Eventstream (Apache Kafka source + vNet injection) → KQL DB

| Pros | Cons |
|------|------|
| **Simplest architecture** — no Event Hub, no Kafka Connect; fewest components | Newer feature (Kafka connector GA July 2026); less community battle-testing |
| **Lowest latency** — Eventstream reads directly from Kafka topic (single hop) | Requires certificate lifecycle management (rotation, expiry) |
| **Full mTLS** — strongest mutual authentication; both sides prove identity via certificates | No Entra ID integration; identity is certificate-based, not token-based |
| **Lower Azure cost** — no Event Hub namespace, no Kafka Connect process | Streaming vNet Data Gateway setup is more involved |
| **Latest Fabric capabilities** — demonstrates GA Eventstream Kafka connector with private network | Only Fabric can consume from this path (no multi-consumer) |

## When to Use Which Solution

Use this decision guide to select the right architecture for your scenario:

### Choose Solution A (Event Hub Bridge) when:

- **Your organization standardizes on Entra ID** — you need audit trails, conditional access, and RBAC-based authorization without managing certificates
- **Multiple consumers need the data** — besides Fabric, you also feed Stream Analytics, Azure Functions, or third-party systems from the same stream
- **You want operational decoupling** — Kafka and Fabric can be upgraded, scaled, or restarted independently with Event Hub absorbing spikes as a buffer
- **Certificate management is unacceptable** — your security team mandates zero-secret, token-based authentication and will not approve custom CA infrastructure
- **You're in a regulated environment** — you need fine-grained RBAC, Azure Policy integration, and identity-based access logs that tie back to Entra ID principals

### Choose Solution B (Direct Kafka Ingestion) when:

- **Latency is critical** — you need the shortest path from Kafka partition to KQL table (single network hop, no intermediate store)
- **Cost is the priority** — you want to avoid the Event Hub namespace cost (~€500+/month for dedicated, ~€30/month for Standard) and keep the architecture lean
- **Fabric is the sole consumer** — no other services need real-time access to this stream
- **You already have certificate infrastructure** — you run an internal CA, have rotation automation (e.g., cert-manager), and mTLS is standard practice in your organization
- **Simplicity of moving parts** — fewer components means fewer failure modes and a smaller blast radius for incidents

### Quick Decision Matrix

| Criterion | Solution A (Event Hub) | Solution B (Direct) |
|-----------|:---------------------:|:-------------------:|
| Auth model | OAuth / Managed Identity | mTLS / Certificates |
| Latency | ~seconds (buffered) | ~milliseconds |
| Azure cost | Higher (Event Hub + Connect) | Lower (Kafka only) |
| Multi-consumer | ✅ | ❌ (Fabric only) |
| Entra ID integration | ✅ | ❌ |
| Certificate management | Not needed | Required |
| Fabric feature maturity | GA (2018+) | GA (July 2026) |
| Operational complexity | Medium (more components) | Low (fewer components) |
| Best for | Enterprise / multi-team | Single-team / cost-sensitive |

## Security Model

### Protocol Hierarchy

```
Security Protocol (pick ONE per connection):
│
├── SSL (mTLS)        ← encryption + certificate-based mutual auth
│                       Identity = certificate. No passwords or tokens.
│
└── SASL_SSL          ← encryption + SASL-based auth
    │                   Server cert for encryption. SASL proves client identity.
    │
    └── SASL Mechanism (pick ONE):
        ├── PLAIN         ← username + password (e.g., connection string)
        ├── SCRAM-SHA-512 ← salted challenge-response (hashed, stronger)
        └── OAUTHBEARER   ← short-lived token from identity provider
                            └── Microsoft Entra ID (the token issuer)
```

### What excludes what

| Pair | Relationship |
|------|-------------|
| mTLS vs SASL_SSL | **Mutually exclusive** — different security protocols |
| PLAIN vs SCRAM vs OAUTHBEARER | **Mutually exclusive** — one SASL mechanism per connection |
| SASL_SSL + OAuth | **Complementary** — OAuth runs *inside* SASL_SSL |
| SASL_SSL + Entra ID | **Complementary** — Entra ID is the token issuer for OAUTHBEARER |
| mTLS + OAuth | **Cannot combine** (in Kafka) — different security protocols |

### Per-Solution Security

| Segment | Solution A | Solution B |
|---------|-----------|-----------|
| Generator → Kafka | PLAINTEXT (private VNet) | mTLS (client cert required) |
| Kafka → Fabric | SASL_SSL + OAUTHBEARER (Managed Identity → Event Hub) | SSL/mTLS (Eventstream connector presents client cert from Key Vault) |
| Network isolation | Private Endpoint (Event Hub) | vNet injection (Streaming vNet Data Gateway) |
| Secret management | Zero-secret (OAuth tokens auto-rotate) | Certificates in Azure Key Vault (PEM format) |

## Repo Structure

```
├── README.md                          ← You are here
├── solution-a/                        ← Event Hub Bridge
│   ├── README.md                      # Deployment guide
│   ├── infra/                         # Bicep: VNet, Event Hub, PE, VM, RBAC
│   ├── kafka/                         # Docker Compose + Kafka Connect (OAuth)
│   ├── event-generator/               # Python producer
│   └── fabric/                        # Eventstream from Event Hub
│
└── solution-b/                        ← Direct Kafka Ingestion
    ├── README.md                      # Deployment guide
    ├── infra/                         # Bicep: VNet, VM, Key Vault, certs
    ├── kafka/                         # Docker Compose (SSL/mTLS listener)
    ├── event-generator/               # Python producer with mTLS
    └── fabric/                        # Eventstream Kafka source + vNet gateway
```

## Prerequisites

- Azure subscription with Contributor/Owner access
- Azure CLI ≥ 2.60
- Fabric capacity (F SKU or Trial) in West Europe
- SSH key pair (ed25519 recommended)

## Quick Start

Each solution deploys independently. See the README in each solution folder:

- **[Solution A — Event Hub Bridge](solution-a/README.md)**
- **[Solution B — Direct Kafka Ingestion](solution-b/README.md)**

## Cleanup

```bash
# Solution A
az group delete --name rg-kafka-bridge-01 --yes --no-wait

# Solution B
az group delete --name rg-kafka-direct-01 --yes --no-wait
```
