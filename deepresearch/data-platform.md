# An Opinionated Open-Source Data + AI Platform on Kubernetes — 2025–2026 Reference Architecture

## TL;DR
- **Build it on Iceberg.** Standardize on Apache Iceberg v3 (ratified in early 2026, production-mature in Iceberg 1.11.0 released May 19 2026) behind an **Apache Polaris** REST catalog (graduated from incubation to ASF top-level project on February 18, 2026, latest release Polaris 1.4) running on **MinIO** (or, if its AGPLv3 + maintenance-mode trajectory worries you, **Ceph RGW / SeaweedFS / Garage**) — this is the only piece of the stack where a wrong choice is genuinely hard to reverse.
- **Two compute planes, one catalog.** Use **Trino** as the federated, ANSI-SQL "lake brain," **StarRocks** as the high-concurrency, sub-second serving engine on the same Iceberg tables, **Kafka (Strimzi) + Flink (Flink Kubernetes Operator 1.13.0, released September 29, 2025)** for streaming, and **Apache Pinot** as the optional real-time OLAP store for true millisecond user-facing analytics. For ML/GenAI, **KubeRay** is the unified compute substrate; **vLLM behind KServe** is the inference plane.
- **Orchestrate with Dagster, transform with dbt-core + SQLMesh, govern with DataHub + OpenLineage, secure with Keycloak + OPA + External Secrets + Vault/OpenBao, observe with the Prometheus/Grafana/Loki/Tempo/OTel quartet.** Stay Apache 2.0 / BSD wherever possible; quarantine the AGPL/SSPL/BSL traps (MinIO AGPLv3, Elasticsearch SSPL, MongoDB SSPL, Redis SAL, Grafana AGPLv3 server, Vault BSL) up front.

---

## Key Findings

1. **The Iceberg catalog war is settled enough to commit.** Apache Polaris graduated from the ASF incubator to top-level project on February 18, 2026 (per the Dremio GlobeNewswire announcement and Snowflake engineering blog "Apache Polaris 1.4 Release"). Snowflake, Dremio, Google, Microsoft, Confluent, and AWS all contribute. The 1.4 release ships hardened Helm charts with native Kubernetes Gateway API support, OPA integration, federated catalog credential vending, and a JSON schema to prevent misconfiguration. Lakekeeper (Rust, single-binary, OpenFGA-backed) is the credible #2 for Kubernetes-minimalist teams. Gravitino is the multi-source federation play. Nessie is for Git-style branching. Unity Catalog OSS exists but is Databricks-gravitational. **Default: Polaris. Minimal ops surface: Lakekeeper.**

2. **Trino vs. StarRocks is not either/or.** Trino remains the federation king (50+ connectors, mature Iceberg + Delta + Hudi support) and the best ANSI-SQL engine for ad-hoc data-lake querying. StarRocks's C++ vectorized MPP engine is materially faster on Iceberg/Parquet for concurrent BI workloads (CelerData/StarRocks-published TPC-DS 1 TB benchmarks claim ~5.5× over Trino — vendor-published, treat as directional). The honest 2026 default is to run **both** on the same Iceberg warehouse: Trino for federation and exploration, StarRocks for BI dashboards and serving.

3. **OLAP real-time tier: Pinot wins for user-facing, ClickHouse for log/observability, StarRocks if you want one engine.** Druid's no-row-level-update limitation and operational complexity make it the weakest of the four in 2026. ClickHouse's 2024–25 lightweight-updates and v25.8 vector search add a credible "single-engine" story for append-heavy + observability. Pinot's star-tree index and tiered storage (StarTree-led) keep it the latency king for user-facing analytics. **Default to Pinot for true real-time UI workloads; skip it entirely if StarRocks's sub-second performance is enough.**

4. **Streaming: Kafka + Flink, deployed by their respective Kubernetes operators, is the boring correct answer.** Strimzi is a CNCF incubating project, KRaft-native, and the Flink Kubernetes Operator 1.13.0 (released September 29, 2025 per the Apache Flink project blog) added Flink 2.1 support and structured-YAML configuration. RisingWave is a genuinely interesting streaming-SQL + materialized-view alternative for teams that don't already need Kafka — but Kafka's ubiquity makes it the safer ingest bus.

5. **Orchestration: Dagster is the recommendation for greenfield analytics+ML platforms.** Asset-centric model + first-class dbt/Spark/Iceberg integration + Components GA on September 18, 2025 (per Dagster's own blog post announcing GA in Dagster 1.11) + FreshnessPolicy GA. Airflow 3.1/3.2 closed many gaps (HITL, asset partitioning, multi-team), and remains the safe enterprise default if you already run it. Prefect is best for dynamic Python-heavy pipelines. Flyte is the niche pick if Kubernetes-native ML DAGs dominate.

6. **Transformation: dbt-core stays the standard; SQLMesh is the deliberate upgrade.** SQLMesh's SQLGlot-based parsing, virtual dev environments, native Python models, and the Tobiko/Databricks-published benchmark — running TPC-DI on a Databricks 2X-Small SQL Serverless warehouse and showing SQLMesh "9× faster and cheaper in routine data transformation tasks" per the March 25, 2025 BusinessWire GA announcement — are real differentiators. dbt's Fusion engine (Rust, ~30× parsing speedup per dbt Labs) closes part of the gap. **Default to dbt-core for ecosystem breadth; choose SQLMesh if cost of dev environments or correctness-under-change is your top pain.**

7. **ML/GenAI: Ray (now under the PyTorch Foundation) is the unified compute substrate.** Ray joined the PyTorch Foundation on October 22, 2025 at PyTorch Conference (San Francisco), per the Linux Foundation press release ("The PyTorch Foundation… today announced that it has welcomed Ray as its newest foundation-hosted project"), sitting alongside vLLM. The KubeRay operator manages `RayCluster`, `RayJob`, and `RayService` CRDs and is the production-credible way to do distributed training + Ray Data + Ray Serve. For LLM inference, **vLLM** is the default — TGI entered maintenance mode on December 11, 2025 (Hugging Face's own deprecation). The Red Hat Developer benchmark by Harshith Umesh, published August 8, 2025, plus Clore.ai's third-party-referenced figures (Ollama ~150 tok/s total vs. vLLM ~800 tok/s at 10 concurrent users on Llama 3.1 8B / RTX 4090, and ~793 vs ~41 tok/s at peak concurrency on identical hardware) make this the clearest decision in the stack. SGLang is a reasonable alternative for prefix-heavy or reasoning-model workloads.

8. **Vector DB: Milvus for scale, Qdrant for filtered RAG, Weaviate for hybrid + graph.** All three are Apache 2.0. Milvus's disaggregated architecture and Kubernetes operator make it the safest pick for billion-scale corpora; Qdrant (Rust, ACORN filtered HNSW) is the leanest production pick for typical RAG; Weaviate's BlockMax WAND hybrid search is best when keyword + vector quality is the dominant requirement.

9. **MinIO is in trouble. Plan accordingly.** MinIO went AGPLv3 in 2021, stripped admin features out of the community console in early 2025, removed pre-compiled community binaries, and the project entered maintenance mode in December 2025 (per InfoQ Dec 2025 reporting and community discussion). For an opinionated 2026 build, **default to MinIO only if you accept AGPLv3 and the stagnation risk**; otherwise plan for **Ceph RGW (LGPL)**, **SeaweedFS (Apache 2.0)**, or **Garage (AGPLv3 but actively developed and explicitly geo-distributed)**.

10. **License gravity matters more than feature counts.** ASF projects (Iceberg, Polaris, Spark, Flink, Kafka, Pinot, Druid, Superset, Airflow; Trino is LF) are the safe core. Active landmines to avoid: **Elasticsearch SSPL → OpenSearch (Apache 2.0)**; **MongoDB SSPL → PostgreSQL**; **Redis SAL/RSALv2 → Valkey (BSD)**; **Vault BSL since Aug 2023 → OpenBao if MPL-2.0 is required**; **Grafana/Loki/Tempo AGPLv3 server (internal use is fine; SaaS resale isn't)**; **MinIO AGPLv3 + maintenance mode → see #9**; **ClickHouse Apache 2.0 is fine, but ClickHouse Cloud is not; Druid/Pinot are Apache 2.0 but Imply Polaris and StarTree Cloud are not**.

---

## Details

### Layered Reference Architecture (Text Diagram)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  CONSUMPTION                                                                 │
│   BI/Viz: Apache Superset │ Notebooks: JupyterHub │ Apps: REST/GraphQL       │
│   GenAI UIs: Open WebUI / custom React + LangGraph agents                    │
└────────────▲────────────────────────▲──────────────────────▲─────────────────┘
             │                        │                      │
┌────────────┴────────────────────────┴──────────────────────┴─────────────────┐
│  SERVING                                                                     │
│   SQL Federation: Trino    │ Real-time BI: StarRocks │ Real-time OLAP:       │
│   Apache Pinot (optional)  │ Model Inference: KServe + vLLM (LLMs) /         │
│   KServe + Triton (classical) │ Vector: Milvus │ Feature Online: Feast       │
└────────────▲────────────────────────▲──────────────────────▲─────────────────┘
             │                        │                      │
┌────────────┴────────────────────────┴──────────────────────┴─────────────────┐
│  PROCESSING / TRANSFORMATION                                                 │
│   Batch ETL: Spark (Spark K8s Operator) │ Streaming: Flink (Flink K8s Op)    │
│   Transform: dbt-core (+ SQLMesh)        │ ML compute: Ray (KubeRay)         │
│   Orchestration: Dagster (Helm)          │ Data quality: Soda + GE + dbt     │
│   Embedding pipelines: Ray Data + sentence-transformers / vLLM-embed         │
└────────────▲────────────────────────▲──────────────────────▲─────────────────┘
             │                        │                      │
┌────────────┴────────────────────────┴──────────────────────┴─────────────────┐
│  STORAGE / LAKEHOUSE                                                         │
│   Table format: Apache Iceberg v3   │ Catalog: Apache Polaris (REST)         │
│   Object store: MinIO / Ceph RGW / SeaweedFS (S3 API)                        │
│   Streaming bus: Apache Kafka (Strimzi operator) + Apicurio Schema Registry  │
│   Feature offline: Iceberg tables (Feast offline store)                      │
│   Vector store: Milvus (or Qdrant) │ Feature online: Valkey (Redis-compat)   │
└────────────▲────────────────────────▲──────────────────────▲─────────────────┘
             │                        │                      │
┌────────────┴────────────────────────┴──────────────────────┴─────────────────┐
│  INGESTION                                                                   │
│   CDC: Debezium → Kafka  │ Batch ELT: Airbyte / Meltano │ Streaming:         │
│   Kafka Connect / Flink CDC │ Doc ingest: Unstructured.io + Ray Data         │
└────────────▲─────────────────────────────────────────────────────────────────┘
             │
   ┌─────────┴──────────┐
   │  SOURCES:          │ OLTP DBs (Postgres/MySQL), SaaS APIs, files (S3),
   │                    │ Kafka producers, document repos (S3, SharePoint, Confluence)
   └────────────────────┘

CROSS-CUTTING (run as platform namespaces, all Kubernetes-native):
  - Catalog & metadata:  DataHub (UI + metadata graph), OpenLineage + Marquez
  - Governance / authz:  Apache Ranger or OPA (per-engine), policy bundles via OCI
  - Identity:            Keycloak (OIDC) → all engines, Superset, JupyterHub, KServe
  - Secrets:             HashiCorp Vault (or OpenBao) + External Secrets Operator
  - Observability:       Prometheus + Grafana + Loki + Tempo + OpenTelemetry Collector
  - GitOps / CD:         Argo CD (or Flux), Helm charts pinned in a platform repo
```

### Complete Component Table

| Capability | Primary OSS Pick | Alternatives | License | Maturity (2026) | K8s Story |
|---|---|---|---|---|---|
| Object storage (S3 API) | **MinIO** (or Ceph RGW if AGPL is a blocker) | SeaweedFS, Garage, Ceph RGW, Apache Ozone | AGPLv3 (MinIO) / LGPL (Ceph) / Apache 2.0 (SeaweedFS) / AGPLv3 (Garage) | MinIO in maintenance mode Dec 2025; Ceph/SeaweedFS active | Operator + Helm |
| Table format | **Apache Iceberg v3** | Delta Lake (LF AI&Data), Apache Hudi, DuckLake | Apache 2.0 | v3 ratified early 2026; production at 1.11.0 (May 19 2026) | n/a (library) |
| Iceberg catalog | **Apache Polaris 1.4** | Lakekeeper, Gravitino, Nessie, Unity Catalog OSS | Apache 2.0 | TLP (graduated Feb 18 2026) | Official Helm chart w/ Gateway API + JSON schema |
| Federated SQL engine | **Trino** | Presto, StarRocks, Dremio OSS, DuckDB (single-node) | Apache 2.0 | Mature (LF Trino Software Foundation) | Trino Helm chart; community operator |
| MPP analytical engine | **StarRocks** | ClickHouse, Apache Doris | Apache 2.0 | Mature; 4.0 added first-class Iceberg | StarRocks Operator |
| Real-time OLAP | **Apache Pinot** | Druid, ClickHouse, StarRocks | Apache 2.0 | Mature (LinkedIn, Uber, Stripe in production) | Pinot Helm + community operator |
| Streaming bus | **Apache Kafka** | Apache Pulsar, Redpanda (BSL) | Apache 2.0 | Industry standard, KRaft-native | **Strimzi** operator (CNCF incubating) |
| Stream processing | **Apache Flink** | Spark Structured Streaming, Kafka Streams, RisingWave | Apache 2.0 | Mature; Flink 2.1 GA | **Flink Kubernetes Operator 1.13.0** (Sep 29 2025) |
| Batch processing | **Apache Spark** | Ray Data, Trino batch | Apache 2.0 | Spark 4.0 has best Iceberg v3 support | **Spark Operator** (Kubeflow) |
| CDC ingestion | **Debezium** → Kafka → Iceberg sink | Airbyte (uses Debezium internally), Flink CDC, Estuary OSS | Apache 2.0 | Mature | Strimzi KafkaConnect + Debezium connectors |
| Batch / SaaS ingestion | **Airbyte OSS** | Meltano (Singer), dlt, Kestra | Elastic v2 / MIT (dlt) / MPL (Meltano) | Active; Airbyte is open-core | Helm chart |
| Orchestration | **Dagster** | Airflow 3, Prefect, Flyte, Argo Workflows | Apache 2.0 | Asset-graph model, Components GA Sep 18 2025 | Dagster Helm chart |
| Transformation | **dbt-core** (+ optional **SQLMesh**) | SQLMesh standalone | Apache 2.0 | dbt is the standard; SQLMesh is the upgrade | Run as Dagster/Airflow assets |
| Data quality | **Soda Core** + **dbt tests** | Great Expectations, Deequ | Apache 2.0 | Mature for tests; Soda for monitoring | Run inside orchestrator |
| Data catalog & metadata | **DataHub** | OpenMetadata, Amundsen, Apache Atlas | Apache 2.0 (DataHub, OpenMetadata, Atlas) | DataHub strongest for event-driven metadata + ML | DataHub Helm chart |
| Lineage | **OpenLineage + Marquez** | DataHub native lineage, Egeria | Apache 2.0 | OpenLineage is LF AI&Data graduate | Marquez Helm; OL agents in Spark/Flink/Airflow/dbt |
| Access control | **Apache Ranger** (engine-level) + **OPA** (catalog/k8s) | Polaris built-in RBAC, OpenFGA (Lakekeeper) | Apache 2.0 | Ranger mature for Trino/Spark/Hive; OPA universal | Ranger Helm (community); OPA Gatekeeper |
| Identity / OIDC | **Keycloak** | Authentik, Zitadel, Dex | Apache 2.0 (Keycloak/Dex), MIT (Authentik) | Keycloak is the de-facto OIDC IdP | Keycloak Operator |
| Secrets | **External Secrets Operator** + **HashiCorp Vault** (community) | sealed-secrets (Bitnami), OpenBao (Vault fork after BSL) | Apache 2.0 (ESO, sealed-secrets) / MPL-2.0 (OpenBao) / BSL (Vault) | ESO + Vault is standard; OpenBao is the Apache-ecosystem-friendly fork | Operators + CRDs |
| Notebook / IDE | **JupyterHub** + JupyterLab + **code-server** | Zeppelin, VSCode Server | BSD / MIT | Mature | Z2JH Helm chart |
| BI / Viz | **Apache Superset** | Metabase, Lightdash (dbt-native), Grafana (ops) | Apache 2.0 / AGPLv3 (Metabase, Grafana server) | Superset 4.x is feature-complete; Lightdash if dbt-centric | Superset Helm |
| ML training | **Kubeflow Training Operator** + **Ray Train (KubeRay)** | Volcano, Argo Workflows | Apache 2.0 | Both mature; Ray is converging unified compute | Operators |
| ML experiment tracking | **MLflow** | Weights & Biases (commercial), Aim (OSS) | Apache 2.0 | Standard; integrates with Dagster, Kubeflow | MLflow Helm + Postgres + S3 |
| Model registry | **MLflow Model Registry** (same install) | Kubeflow Model Registry (newer) | Apache 2.0 | Mature | same |
| Feature store | **Feast** | Hopsworks (open-core; some AGPL parts) | Apache 2.0 | Mature; Iceberg offline, Valkey/DynamoDB online | Feast on K8s; Charmed Feast (Canonical, Jul 2025) |
| Model serving (classical + LLM) | **KServe** | Seldon Core v2 (BSL), BentoML | Apache 2.0 | KServe is the CNCF standard; supports vLLM and Triton runtimes | Native CRDs |
| LLM inference engine | **vLLM** | SGLang, Triton + TensorRT-LLM, Ollama (dev), TGI (deprecated Dec 11 2025) | Apache 2.0 | TGI maintenance mode; vLLM is the default | vLLM Helm + KServe ServingRuntime |
| Vector DB | **Milvus** (scale) or **Qdrant** (RAG) | Weaviate, pgvector, LanceDB | Apache 2.0 | All three are production-grade | Milvus operator; Qdrant Helm |
| Embeddings pipeline | **Ray Data** + sentence-transformers / vLLM embeddings | Spark + UDFs | Apache 2.0 | Standard pattern | KubeRay |
| RAG / agent framework | **LangGraph** (orchestration) + **LlamaIndex** (retrieval) | Haystack (regulated/auditable), DSPy (compiled), CrewAI | MIT / Apache 2.0 | LangGraph for stateful agents; LlamaIndex for indexing | Containerized apps |
| Observability metrics | **Prometheus** + **Grafana** | VictoriaMetrics, Mimir | Apache 2.0 (Prom) / AGPLv3 (Grafana server, OSS) | CNCF graduated | Prometheus Operator |
| Logs | **Loki** | OpenSearch (Apache 2.0, ES-SSPL fork) | AGPLv3 (Loki) | Mature | Loki Helm |
| Tracing | **Tempo** + **OpenTelemetry Collector** | Jaeger | AGPLv3 (Tempo) / Apache 2.0 (OTel, Jaeger) | OTel is the CNCF standard wire format | OTel Operator |
| GitOps / CD | **Argo CD** | Flux CD | Apache 2.0 | CNCF graduated | Argo CD Helm |

---

### Concrete End-to-End Data Flow Scenarios

#### Scenario A — Batch ETL: Postgres → Iceberg → dbt → Superset

1. **Source.** Application Postgres instance, accessed via Debezium PostgreSQL connector deployed in a **Strimzi KafkaConnect** cluster.
2. **CDC capture.** Debezium reads the WAL via `pgoutput`, emits row-level change events to Kafka topics (`app.public.<table>`) keyed by primary key.
3. **Landing.** A Kafka Connect **Iceberg Sink connector** (or the **Debezium Server Iceberg consumer** for setups without Kafka) commits batched Avro/JSON records into a `bronze.<table>` Iceberg table registered in **Apache Polaris**. Commits use Iceberg v3 merge-on-read with deletion vectors for upserts.
4. **Catalog & lineage.** Polaris registers the table; OpenLineage events emitted from the connector flow to **Marquez**, and via DataHub's OpenLineage receiver, into **DataHub**.
5. **Transformation.** A **Dagster** asset graph triggers **dbt-core** running against Trino (via the `dbt-trino` adapter). dbt models build `silver.*` and `gold.*` Iceberg tables; dbt tests and Soda checks run as Dagster asset checks; failures block downstream materializations.
6. **Serving.** Superset connects to **Trino** for ad-hoc exploration and to **StarRocks** (which mounts the same Iceberg tables as an external catalog) for high-concurrency dashboards.
7. **Governance.** Apache Ranger policies attached to Trino (and to StarRocks via the Ranger plugin) enforce row/column-level masking. Keycloak issues OIDC tokens; Superset, Trino, StarRocks, and JupyterHub all federate to the same realm.

#### Scenario B — Streaming: Kafka → Flink → Pinot → Real-time Dashboard

1. **Producers** push events to Kafka topics managed by Strimzi (`KafkaTopic` CRDs); schemas are registered in **Apicurio Registry** or **Karapace** (Apache 2.0 alternatives to Confluent Schema Registry).
2. A **FlinkDeployment** (Flink K8s Operator 1.13.0) runs a SQL job that joins streaming order events with a CDC-derived customer dimension (a Flink Iceberg-Hybrid source reads Iceberg snapshots + live Kafka topics).
3. Flink writes enriched events to (a) an Iceberg `silver.orders_enriched` table (for batch reuse) and (b) a **Pinot** real-time table that ingests directly from the upstream Kafka topic for sub-second user-facing analytics.
4. Pinot's star-tree index pre-aggregates `(merchant_id, hour)` for the most common dashboard query path.
5. **Superset** queries Pinot directly via the Pinot SQL connector; refresh cadence on the dashboard is set to 5 s.
6. OpenLineage Flink integration emits run/job/dataset events to Marquez; the same dataset appears in DataHub's lineage graph.

#### Scenario C — ML: Feature engineering → Feast → Training → Registry → KServe

1. **Feature engineering.** A Dagster job runs Spark on Kubernetes (Spark Operator) over Iceberg silver/gold tables, producing point-in-time correct feature dataframes, and registers them as **Feast** `FeatureView`s. Offline store is Iceberg; online store is **Valkey** (Redis-compatible, BSD).
2. **Training.** A **Kubeflow Pipelines** run (or alternatively a `RayJob` via KubeRay) reads training features via `feast.get_historical_features()`, trains an XGBoost or PyTorch model on Ray Train across multiple GPU pods, and logs metrics/artifacts to **MLflow**.
3. **Registry.** The candidate model is registered in **MLflow Model Registry** with `staging` → `production` transitions gated by a manual approval step in Dagster (or Kubeflow).
4. **Serving.** A `KServe InferenceService` (predictor: custom Python or `kserve-tritonserver` runtime) is deployed, with the model artifact loaded from MLflow's S3-backed artifact store. The predictor's `preprocess` hook calls `feast.get_online_features()` to enrich the inference payload with fresh online features.
5. **Monitoring.** Prometheus scrapes KServe metrics; data drift and prediction drift checks are scheduled as Dagster asset checks against a `predictions` Iceberg table populated by KServe's logger.

#### Scenario D — GenAI/RAG: Docs → Embeddings → Milvus → vLLM → LangGraph agent

1. **Document ingestion.** A Dagster sensor watches a source (S3 prefix, SharePoint connector, Confluence). New documents are queued.
2. **Parsing/chunking.** A `RayJob` runs **Unstructured.io** over each document (PDF, DOCX, HTML) and chunks the output with LlamaIndex's semantic chunker. Chunks are written as a `documents.chunks` Iceberg table (raw text + metadata + source URI).
3. **Embedding.** A second Ray Data job batches chunks through a **vLLM**-served embedding model (e.g., `BAAI/bge-large-en-v1.5` or `nvidia/nv-embed-v2`) exposed via the OpenAI-compatible `/v1/embeddings` endpoint. Vectors + metadata are upserted into **Milvus** collections.
4. **Retrieval.** The agent service (containerized FastAPI) uses **LlamaIndex** as the retrieval layer (hybrid search: Milvus vectors + BM25 reranking) and **LangGraph** for the stateful multi-step agent (retrieval → tool calls → critique → answer).
5. **Generation.** A second `KServe InferenceService` runs a chat-tuned model (e.g., Llama 3.3 70B or Qwen 3) on **vLLM** with tensor-parallel size 4 across H100 GPUs. The LangGraph state machine streams tokens back to the client.
6. **Observability.** OpenTelemetry traces span the entire agent call (LangGraph → LlamaIndex → vLLM); Grafana/Tempo render the trace. Prompts/responses are logged to an Iceberg `agent.traces` table for eval and red-teaming.
7. **Governance.** Keycloak issues per-user JWTs; an OPA sidecar on the agent service enforces per-tenant data-access policies before retrieval (`only retrieve chunks where tenant_id = user.tenant`).

---

### Kubernetes Deployment Topology

**Namespaces** (one per logical platform layer; NetworkPolicies enforce least-privilege between them):

| Namespace | Workloads |
|---|---|
| `platform-ingress` | NGINX or Envoy Gateway, cert-manager, ExternalDNS |
| `platform-identity` | Keycloak, OPA, OPA Gatekeeper |
| `platform-secrets` | Vault (or OpenBao), External Secrets Operator |
| `platform-gitops` | Argo CD |
| `platform-observability` | Prometheus Operator, Grafana, Loki, Tempo, OTel Collector |
| `data-storage` | MinIO (or Ceph RGW), Polaris, DataHub, Marquez |
| `data-streaming` | Strimzi operator, Kafka cluster, KafkaConnect (Debezium), Apicurio |
| `data-processing` | Spark Operator, Flink K8s Operator, FlinkDeployments, Spark jobs (run as Dagster runs) |
| `data-query` | Trino coordinator + workers, StarRocks FE/BE, Pinot controller/broker/server, Superset |
| `data-orchestration` | Dagster webserver/daemon, dbt runners, Soda Core |
| `ml-platform` | Kubeflow (Pipelines, Training Operator, Katib), MLflow, Feast |
| `ml-compute` | KubeRay operator, RayClusters, RayJobs |
| `ml-serving` | KServe, vLLM ServingRuntimes, Triton ServingRuntimes |
| `ml-vector` | Milvus (or Qdrant), Valkey for online features |
| `ml-genai` | LangGraph agents, LlamaIndex retrieval services, Open WebUI |
| `tenant-*` | Per-tenant notebook + scratch namespaces (JupyterHub spawns into these) |

**Operators** (the list every platform team installs day one):
- **Strimzi Cluster Operator** → Kafka, KafkaConnect, KafkaTopic, KafkaUser
- **Apache Flink Kubernetes Operator 1.13.0** (Sep 29 2025) → FlinkDeployment, FlinkSessionJob, FlinkStateSnapshot
- **Apache Spark Operator** (Kubeflow) → SparkApplication
- **KubeRay Operator** → RayCluster, RayJob, RayService
- **KServe** → InferenceService, ServingRuntime, ClusterServingRuntime
- **Kubeflow Training Operator** → PyTorchJob, TFJob, MPIJob, XGBoostJob
- **Apache Polaris Helm chart** (1.4 with Gateway API support)
- **MinIO Operator** (if using MinIO) or **Rook-Ceph operator**
- **Prometheus Operator + OpenTelemetry Operator**
- **Keycloak Operator**
- **External Secrets Operator**
- **cert-manager + Argo CD**

**Storage classes:**
- `fast-ssd` (NVMe, ReadWriteOnce) for Kafka brokers, Polaris/DataHub Postgres, StarRocks BE, Pinot servers, vector DB persistence
- `bulk` (HDD or cheaper EBS) for Spark/Flink shuffle when stateful
- `s3` (CSI/JuiceFS/MountPoint-S3) for Iceberg warehouse paths (logically — engines read S3 directly via boto/aws-sdk)
- GPU nodes use NVIDIA GPU Operator + MIG profiles for inference; full-GPU nodes for training

**Networking:**
- Single mesh (Istio or Linkerd) for mTLS between data-processing and data-query namespaces
- NetworkPolicies deny-all by default; explicit allowlists per cross-namespace path
- Trino, StarRocks, Pinot expose only inside the cluster; Superset and JupyterHub behind OIDC-authenticating ingress
- vLLM endpoints behind KServe's internal gateway; agent service is the only public surface

---

### Default Opinionated Stack (Copy-Paste Picks)

| Layer | Pick | Why |
|---|---|---|
| Object store | **MinIO** (if AGPL ok) or **Ceph RGW** | S3 API, HA, K8s-native |
| Table format | **Apache Iceberg v3** | Won the format war; v3 production-mature May 2026 |
| Catalog | **Apache Polaris 1.4** | TLP since Feb 18 2026; multi-engine via REST spec |
| Federated SQL | **Trino** | Ecosystem breadth; Iceberg + 50 connectors |
| MPP / BI | **StarRocks** | Sub-second on Iceberg, MySQL wire protocol |
| Real-time OLAP | **Apache Pinot** (skip if StarRocks suffices) | User-facing analytics, star-tree index |
| Streaming bus | **Kafka via Strimzi** | KRaft, CNCF, ubiquity |
| Stream processing | **Flink via Flink K8s Operator 1.13.0** | Exactly-once, Iceberg sink |
| Batch processing | **Spark via Spark Operator** | Best Iceberg v3 support |
| Orchestration | **Dagster** (Components GA Sep 18 2025) | Asset graph; first-class dbt/Spark/Iceberg |
| Transformation | **dbt-core (+ SQLMesh for new pipelines)** | dbt is standard; SQLMesh wins on cost/correctness |
| Catalog & metadata | **DataHub** + **OpenLineage/Marquez** | Event-driven metadata + ML assets |
| Identity | **Keycloak** | OIDC for every engine |
| Authz | **Apache Ranger** (engine) + **OPA** (k8s/catalog) | Engine-level row/column; policy-as-code |
| Secrets | **External Secrets Operator + Vault** (or **OpenBao** if BSL is a blocker) | K8s-native secret sync |
| ML training/registry | **Ray (KubeRay) + Kubeflow + MLflow** | Distributed training + experiment tracking |
| Feature store | **Feast** | Iceberg offline + Valkey online |
| Model serving | **KServe + vLLM (LLMs) / Triton (classical)** | vLLM is the 2026 default; TGI deprecated Dec 11 2025 |
| Vector DB | **Milvus** (scale) or **Qdrant** (filtered RAG) | Both Apache 2.0, K8s-native |
| RAG framework | **LangGraph + LlamaIndex** | Stateful agents + retrieval-first ingestion |
| BI | **Apache Superset** (or **Lightdash** if dbt-only) | Superset is the broadest OSS BI; Lightdash if dbt-centric |
| Observability | **Prometheus + Grafana + Loki + Tempo + OTel** | The standard stack |

---

### Cost / Complexity Trade-Offs

**Minimal Viable (MVP) version** — fits one Kubernetes cluster, 1 platform engineer, single-team scale:
- Drop StarRocks; let Trino serve BI directly (slower, but one fewer engine).
- Drop Pinot entirely; Trino-on-Iceberg with materialized views handles dashboards.
- Drop Kubeflow; use only Ray (KubeRay) + MLflow + KServe.
- Drop DataHub; use **OpenMetadata** as a single-binary alternative, or live with Polaris's built-in browse for the first 6 months.
- Drop Ranger; use Polaris's built-in RBAC + Keycloak groups.
- Drop Vault; use sealed-secrets only.
- Drop the agent layer; stand up a single FastAPI app that calls vLLM directly via OpenAI SDK.
- Skip Iceberg v3-specific features (deletion vectors, row lineage) until you actually need them.

**Full Enterprise** version — multi-tenant, regulated, multi-region:
- Add **Apache Ranger** for engine-level row/column masking with audit to a SIEM.
- Add **OPA Gatekeeper** as a Kubernetes admission controller for all platform CRDs.
- Run a dedicated **Polaris** instance per business unit, federated via Gravitino for cross-domain queries.
- Multi-cluster Kafka with MirrorMaker 2 (managed by Strimzi).
- Dedicated GPU pool with **MIG slicing** for fractional inference; **InfiniBand** (where available) for distributed training.
- Add **Karpenter** (or Cluster Autoscaler) for spot-bias node scaling.
- Add a vector reranker tier (cross-encoder via Triton) for RAG quality.
- Switch online feature store to a hardened **Valkey** cluster with replication.
- Run **Argo Workflows** alongside Dagster for heavy K8s-native fan-out (e.g., per-tenant model retraining).

---

### Risks, Anti-Patterns, License Traps

**License landmines (the short, decision-relevant version):**
- **MinIO** is AGPLv3 *and* in maintenance mode (per InfoQ, Dec 2025). If you embed MinIO in a product you sell, AGPLv3 forces source disclosure for any modified code; if you self-host purely for internal use you are fine, but the maintenance-mode trajectory is a real availability risk. **Have a Ceph / SeaweedFS / Garage migration plan written down.**
- **Elasticsearch is SSPL** (and Elastic License). Use **OpenSearch** (Apache 2.0) for log/search, not the upstream ES.
- **MongoDB is SSPL.** This stack does not depend on MongoDB; if a vendor's "open source" component ships MongoDB, treat it as a SaaS dependency.
- **Redis** changed to **RSALv2/SSPL** in 2024. Use **Valkey** (Linux Foundation, BSD) as a drop-in.
- **HashiCorp Vault** is **BSL** since August 2023; the community fork is **OpenBao** (LF, MPL-2.0). Either works; OpenBao is the safer pick if BSL is unacceptable.
- **Grafana** server is **AGPLv3** since v8.x. Internal use is unproblematic; offering Grafana-as-a-service to third parties triggers AGPL obligations. **Loki / Tempo / Mimir** are all AGPLv3 (Grafana Labs) — same considerations.
- **ClickHouse** is Apache 2.0 — fine. But **Druid is Apache 2.0** while **Imply Polaris** (Druid's commercial cloud) is not — don't confuse them; same for **Pinot** vs **StarTree Cloud**.
- **Confluent Community License** (Schema Registry, ksqlDB) is *not* OSI-approved. Use **Apicurio Registry** (Apache 2.0) or **Karapace** (Apache 2.0) instead.
- **Airbyte Connector Builder Kit** is MIT, but several Airbyte connectors are under the Elastic License v2; check per-connector if you redistribute.
- **Seldon Core v2** moved to BSL; **KServe** (Apache 2.0) is the safer model-serving pick.
- **Polaris graduated to TLP February 18, 2026** — the "-incubating" suffix is now gone from 1.4 and later releases; older 1.3.0-incubating Helm charts are still pinnable.

**Anti-patterns to avoid:**
- **Running Polaris/Trino/StarRocks all against three different catalogs.** Single source of catalog truth (Polaris) is the whole point.
- **Writing to Iceberg from two engines without coordinating compaction.** Schedule a single compaction job (Spark or Trino's `OPTIMIZE` / `ALTER TABLE EXECUTE optimize`) per table per hour.
- **Using Druid without a clear story for updates.** Druid has no row-level UPDATE/DELETE; only batch re-ingestion. If your data mutates, prefer Pinot, StarRocks, or ClickHouse.
- **Standing up TGI for new LLM workloads in 2026.** TGI has been in maintenance mode since December 11, 2025 — go straight to vLLM (or SGLang for prefix-heavy).
- **Bolting LangChain onto everything.** LangGraph is the agent runtime; LangChain proper has had aggressive breaking changes across 0.1/0.2/0.3.
- **Running ZooKeeper-mode Kafka.** ZooKeeper is deprecated as of Kafka 3.3 — use **KRaft** mode (the Strimzi default for new clusters).
- **Using MinIO's web console in production.** Admin UI has been stripped from the community edition since early 2025; rely on `mc` CLI or migrate.
- **Mixing dbt and SQLMesh in the same pipeline DAG without clear boundaries.** Pick per project; they compete.
- **Forgetting Iceberg orphan-file cleanup.** Schedule `expire_snapshots` + `remove_orphan_files` weekly per table or watch object-store costs balloon.

---

### Emerging 2025–2026 Trends to Factor In

- **Iceberg ecosystem consolidation.** Iceberg v3 (ratified early 2026, production at Iceberg 1.11.0 May 19 2026) brings deletion vectors, row lineage, variant, geo types, and default values into the spec. Polaris is the catalog Schelling point. Engines vary widely on v3 support: Spark 4.0 is the reference, Flink is beta-v3, Trino's v3 support is marked experimental in Trino 481, **StarRocks has no v3 support yet** (community feature request open), Snowflake-managed v3 hit GA May 7 2026, Athena and ClickHouse still v1/v2 only. Plan adoption around your hottest engine.
- **REST catalogs are how the multi-engine future works.** Polaris, Lakekeeper, Gravitino, Nessie, Unity Catalog OSS, and even AWS Glue's IRC endpoint all speak the same Iceberg REST spec. The lock-in surface has moved up the stack (to governance and tooling), not down.
- **Single-node analytics is real.** DuckDB + LanceDB + Polars are eating the bottom of the OLAP market for sub-100 GB workloads. Run them inside notebooks and CI; don't dismiss them for prototyping.
- **Arrow / ADBC** is becoming the wire format. Many engines (DuckDB, Trino, ClickHouse, Polars) speak ADBC; this matters for low-overhead BI tools and ML feature pipelines.
- **OpenTelemetry for data.** OTel is expanding from app traces to data-pipeline traces via OpenLineage and dbt's OL emitter. Treat your pipeline as a distributed system: span it end-to-end.
- **Ray as the unified ML compute substrate.** Ray joined the PyTorch Foundation on October 22, 2025 at PyTorch Conference in San Francisco, sitting alongside vLLM and DeepSpeed. The PyTorch / Ray / vLLM trio is becoming the open AI compute stack.
- **vLLM-style serving is now the default.** PagedAttention, continuous batching, prefix caching, and (via the Red Hat-led llm-d project) disaggregated prefill/decode are now production-required. TGI is deprecated; SGLang is a reasonable alternative for prefix-heavy workloads.
- **MCP (Model Context Protocol)** is becoming the agent-to-tools wire format. LangGraph, LlamaIndex, and most major IDEs support MCP servers. Plan your tool surface around MCP rather than per-framework adapters.
- **Lakehouse-native ML.** Feast offline-on-Iceberg + online-on-Valkey + KServe is the pattern that has won over per-team feature pipelines.

---

## Recommendations

**Stage 1 (Weeks 0–6) — Foundation.** Stand up Kubernetes (vanilla or OpenShift), Argo CD, cert-manager, Keycloak, External Secrets Operator + Vault (or OpenBao), Prometheus/Grafana/Loki/Tempo, and a single-node MinIO (or 3-node Ceph). Deploy Apache Polaris 1.4 via its Helm chart pointed at a Postgres backend. Wire Polaris auth to Keycloak via OIDC. **Decision benchmark:** a Spark job can write an Iceberg table via Polaris from outside the cluster within 4 weeks.

**Stage 2 (Weeks 6–14) — Lakehouse + batch.** Add Strimzi + a small Kafka cluster, Debezium for your top 2–3 source databases, Spark Operator, Trino (with the Iceberg connector pointed at Polaris), and Dagster. Wire dbt-core through Dagster. Stand up DataHub + Marquez and enable OpenLineage emitters on Spark, dbt, and Dagster. Add Superset for BI. **Decision benchmark:** bronze→silver→gold pipeline runs nightly with dbt tests + Soda checks gating downstream materializations.

**Stage 3 (Weeks 14–22) — Streaming + serving.** Add the Flink K8s Operator and one or two streaming pipelines that write to Iceberg and emit to Pinot. Add StarRocks for high-concurrency BI; point Superset at StarRocks for dashboards that exceed Trino's concurrency comfort zone. **Decision benchmark:** a dashboard refreshing every 5 s against streaming data, with the same data also queryable via Trino.

**Stage 4 (Weeks 22–34) — ML platform.** Install KubeRay, Kubeflow, MLflow, Feast (offline on Iceberg, online on Valkey), and KServe. Promote one model to production with feature-store-backed online inference. **Decision benchmark:** end-to-end model retrain + redeploy in under 1 hour from a Dagster trigger.

**Stage 5 (Weeks 34–48) — GenAI/RAG.** Install Milvus, vLLM (via KServe ServingRuntime), Unstructured.io ingestion pipelines on Ray Data, and a LangGraph agent service. Add OPA-based tenant filtering at retrieval time. **Decision benchmark:** RAG agent answers a domain question with citations in <3 s p95, with audit trail in `agent.traces`.

**Thresholds that should change these recommendations:**
- **>100 PB total storage, >50 GB/s read throughput** → revisit Ceph vs. SeaweedFS vs. a commercial object store; AGPL/MinIO becomes a more pressing question.
- **>10,000 concurrent BI users** → StarRocks alone is unlikely to suffice; tier with Pinot or pre-aggregated cubes.
- **>1 B vectors** → Milvus is the only sane pick of the three; Qdrant/Weaviate top out earlier.
- **Strict on-prem air-gapped + regulatory (HIPAA/PCI/Fed)** → switch from MinIO to Ceph; switch from Vault to OpenBao; add Apache Ranger; mandate FIPS-validated TLS and at-rest encryption (Iceberg v3 native encryption helps here).
- **You already run Databricks or Snowflake** → don't replatform. Instead, point them at the same Polaris catalog and run this stack alongside; converge over years, not quarters.

---

## Caveats

- **Benchmarks are vendor-published.** StarRocks's 5.5×-over-Trino TPC-DS number, SQLMesh's 9×-over-dbt-core figure (Tobiko's TPC-DI test on a Databricks 2X-Small SQL Serverless warehouse, March 25, 2025 GA announcement), Pinot's "4× faster than ClickHouse" claim, and vLLM's 793-vs-41 tok/s versus Ollama (Red Hat Developer, August 8, 2025) are all from interested parties (CelerData, Tobiko, StarTree, Red Hat). They are directionally credible because the architectural advantages are real (C++ vectorization, virtual envs, star-tree indexing, PagedAttention) but you should re-benchmark on your data and your hardware before committing.
- **Polaris graduation status has a stale-page caveat.** The Apache Incubator "Clutch" page still listed Polaris as incubating with the 1.3.0-incubating release at the time of this writing; the primary sources (Snowflake engineering blog "Apache Polaris 1.4 Release", Dremio's GlobeNewswire press release of February 18, 2026) confirm graduation to TLP. The 1.3.0-incubating Helm chart is still a valid pinnable artifact; 1.4 drops the suffix.
- **Iceberg v3 engine support is uneven.** Spark 4.0 is the reference. Flink's v3 is beta. Trino's v3 is experimental in Trino 481. StarRocks has no v3 yet. Athena, ClickHouse, BigQuery are still v1/v2 only. If a specific v3 feature (deletion vectors, variant, geo) is mission-critical, pin the engine accordingly.
- **MinIO's future is uncertain.** It went into maintenance mode in December 2025 (per InfoQ). The community license is AGPLv3. Production-grade alternatives (Ceph, SeaweedFS, Garage) are credible but each has its own operational learning curve. Don't treat MinIO as forever; plan migration.
- **TGI users must migrate.** Hugging Face placed TGI into maintenance mode on December 11, 2025, with their own recommendation to move to vLLM or SGLang.
- **The "agent" space is moving weekly.** LangGraph, LlamaIndex, Haystack, DSPy, CrewAI, and AutoGen change APIs faster than this report can stay current; pin versions and budget time for upgrades.
- **License interpretation requires counsel for product use.** AGPLv3 (MinIO, Garage, Grafana server, Loki, Tempo), BSL (Vault, Redpanda, Seldon Core v2), and Elastic v2 / SSPL (Elasticsearch, MongoDB, some Airbyte connectors) can each have surprising consequences if you embed the software in a product you offer to third parties. Internal use is almost always fine; SaaS resale is the danger zone.