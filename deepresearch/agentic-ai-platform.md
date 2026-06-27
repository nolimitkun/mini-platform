# Open-Source, Kubernetes-Native Agentic AI Platform — Reference Architecture (May 2026)

## TL;DR
- Build the agentic plane as four GitOps-managed layers on top of your existing lakehouse: an **Inference Gateway** (Gateway API Inference Extension + Envoy/kgateway with LiteLLM for provider routing), a **GPU model-serving plane** (KServe + vLLM, with llm-d for disaggregated serving at scale), an **agent runtime** (LangGraph packaged on Ray Serve/FastAPI, durable state via Temporal), and a **tool/context layer** built on MCP (mcp-trino and friends) governed by OPA + Keycloak. Everything reuses your Iceberg/Polaris/Trino/Kafka/Milvus/Keycloak/Vault/Prometheus stack.
- The single biggest 2025–2026 shifts to design for are: **MCP + A2A standardization** (both now under Linux Foundation; A2A donated by Google on June 23, 2025 and grown from 50+ to over 150 supporting organizations with 22,000+ GitHub stars), the **Gateway API Inference Extension** becoming the K8s-native way to do KV-cache-aware routing, **disaggregated prefill/decode serving** (llm-d, NVIDIA Dynamo), and **OpenTelemetry GenAI semantic conventions** for tracing — though the GenAI semconv is still experimental ("Development" status as of mid-2026), so pin versions.
- Watch the license traps: **vLLM, KServe, LiteLLM, Langfuse, Temporal Server, kagent, HAMi, LMCache, NVIDIA Dynamo, agentgateway are all Apache-2.0/MIT** and safe for production; **Seldon Core flipped to BSL 1.1 on January 22, 2024** (production now requires a paid commercial license — avoid), and several "OSS" gateways/observability tools are open-core with enterprise gating. Default opinionated stack: vLLM + KServe + llm-d + Gateway API Inference Extension + LiteLLM + LangGraph + Temporal + MCP + Milvus + Langfuse + Ragas/DeepEval + Llama Guard/Presidio + HAMi/MIG + Kueue.

## Key Findings

**1. Model serving is now a first-class, multi-project plane, not a single server.** vLLM is the de-facto default inference engine (Apache-2.0, broadest hardware/model support); SGLang is the credible alternative and is faster on prefix-heavy/RAG and DeepSeek workloads via RadixAttention. Hugging Face put TGI into maintenance mode on December 11, 2025 (per the official TGI docs: "only pull requests for minor bug fixes, documentation improvements, and lightweight maintenance tasks will be accepted"), and now recommends vLLM or SGLang — removing TGI as a serious option for new deployments. Around the engine, a new orchestration tier has emerged: **llm-d** (CNCF Sandbox, founded by Red Hat/Google/IBM/CoreWeave/NVIDIA) and **NVIDIA Dynamo** (Apache-2.0) provide disaggregated prefill/decode, KV-cache-aware routing, and multi-node serving. **LMCache** and **AIBrix** provide KV-cache offloading to CPU/disk/remote, and integrate with vLLM and KServe.

**2. The Kubernetes Gateway API Inference Extension (GAIE) is the standardizing primitive for inference routing.** It adds InferencePool + Endpoint Picker (EPP) CRDs that do model-aware, KV-cache/queue-depth-aware "smart" load balancing, implemented by Envoy Gateway, kgateway, Istio, and NGINX Gateway Fabric. llm-d builds directly on it. This is where to invest rather than ad-hoc Service load balancing.

**3. Agent frameworks have converged on ~4 patterns; LangGraph is the production default.** Graph-based (LangGraph, MS Agent Framework), role-based (CrewAI), handoff (OpenAI Agents SDK), hierarchical (Google ADK). LangGraph wins for stateful, durable, inspectable production workflows. For durable execution, **Temporal Server is MIT-licensed and free to self-host in production** (a common misconception is that it is BSL — it is not; the MIT LICENSE grants unrestricted production use, while only the separate Temporal Cloud managed service is paid).

**4. MCP and A2A are both now Linux Foundation standards.** Per the Linux Foundation, A2A was donated by Google on June 23, 2025 at Open Source Summit North America (founding members AWS, Cisco, Google, IBM, Microsoft, Salesforce, SAP, ServiceNow) and has grown from more than 50 to over 150 supporting organizations. MCP is the tool-connection standard adopted by OpenAI, Google, and Microsoft. Your lakehouse becomes agent-accessible by exposing Trino/StarRocks/Iceberg/Feast/DataHub as MCP servers (mcp-trino is mature, Go-based, supports OAuth/JWT).

**5. Observability/eval/guardrails tooling is mature and mostly permissive.** Per Langfuse's June 4, 2025 announcement, all remaining product features (tracing, LLM-as-a-judge evals, annotation queues, prompt experiments, playground) were open-sourced under MIT; only SCIM, Audit Logs, and Data Retention Policies remain commercial (Langfuse was subsequently acquired by ClickHouse in January 2026, with no license change). Arize Phoenix and OpenLLMetry/Traceloop emit OpenTelemetry GenAI spans. Ragas, DeepEval, Promptfoo are open-source eval frameworks now integrated into MLflow's scorer API. Guardrail models (Llama Guard, ShieldGemma, Granite Guardian) are served like any other model — but independent red-teaming shows they fail badly on novel adversarial prompts, so do not rely on them alone.

## Details

### Layered Reference Architecture (text diagram)

```
                            ┌─────────────────────────────────────────────────────────┐
   Customer / Internal      │  EDGE: Keycloak OIDC  ·  WAF  ·  TLS  ·  Ingress        │
   request (HTTPS/WSS/SSE)─▶│  (existing identity)                                    │
                            └───────────────┬─────────────────────────────────────────┘
                                            ▼
   ┌───────────────────────────────────────────────────────────────────────────────────┐
   │  L1  AI / INFERENCE GATEWAY                                                       │
   │   • kgateway / Envoy Gateway  + Gateway API Inference Extension (InferencePool,   │
   │     Endpoint Picker = KV-cache/queue-aware routing)                               │
   │   • LiteLLM (OpenAI-compatible unified API, virtual keys, per-tenant rate-limit,  │
   │     cost/token accounting, fallback to external providers, semantic cache)        │
   │   • agentgateway (MCP + A2A + LLM proxy, OAuth) for agent/tool traffic            │
   │   • OPA + Keycloak JWT → tenant scoping, quotas; OTel spans emitted here          │
   └───────────────┬───────────────────────────────────────────┬───────────────────────┘
                   ▼                                           ▼
   ┌────────────────────────────────────┐      ┌──────────────────────────────────────┐
   │ L2 AGENT RUNTIME                   │      │ L2' MODEL-SERVING PLANE (GPU)        │
   │  • LangGraph agents (Python)       │      │  • KServe + vLLM (LLM, OpenAI API)   │
   │    packaged on Ray Serve / FastAPI │      │  • llm-d / Dynamo (disagg P/D,       │
   │    (SSE/WebSocket streaming)       │◀────▶│    KV-cache routing) at scale        │
   │  • Temporal (durable, retries,     │      │  • TEI/Infinity (embeddings,         │
   │    checkpointing, timers)          │      │    rerankers)                        │
   │  • kagent for K8s-native agents    │      │  • faster-whisper (STT), TTS         │
   │  • Guardrails: Llama Guard /       │      │  • Llama Guard / ShieldGemma /       │
   │    Presidio / NeMo Guardrails      │      │    Granite Guardian (served models)  │
   └───────┬────────────────────────────┘      │  • LMCache / AIBrix KV offload       │
           ▼                                   └────────────────┬─────────────────────┘
   ┌──────────────────────────────────────────────┐             │
   │ L3 TOOL / CONTEXT LAYER (MCP + A2A)          │             │
   │  • MCP servers: mcp-trino (text-to-SQL,      │             │
   │    read-only, OPA/Ranger enforced),          │             │
   │    StarRocks/Pinot/Feast/DataHub MCP         │             │
   │  • mcp-gateway / agentgateway (tool registry,│             │
   │    OAuth, audit)                             │             │
   │  • Retrieval: LlamaIndex hybrid search +     │             │
   │    reranker over Milvus (tenant-scoped)      │             │
   └───────────────┬──────────────────────────────┘             │
                   ▼                                            ▼
   ┌─────────────────────────────────────────────────────────────────────────────────┐
   │  EXISTING LAKEHOUSE (reused, not redesigned)                                    │
   │  MinIO/Ceph + Iceberg v3 + Polaris  ·  Trino / StarRocks / Pinot                │
   │  Kafka (Strimzi) + Flink + Debezium  ·  Spark  ·  Dagster + dbt/SQLMesh         │
   │  Feast (Iceberg offline / Valkey online)  ·  Milvus  ·  DataHub + OpenLineage   │
   │  Ranger + OPA  ·  Keycloak  ·  Vault/OpenBao + ESO  ·  Prom/Grafana/Loki/Tempo  │
   │  Argo CD (GitOps for everything above)                                          │
   └─────────────────────────────────────────────────────────────────────────────────┘
   Audit/eval loop: prompts, responses, tool calls, lineage → Iceberg tables;
   traces → Tempo/Langfuse via OTel GenAI semconv; cost → Iceberg → Superset/StarRocks.
```

### Component Table (capability → project, license, maturity, K8s, lakehouse integration)

| Capability | Primary (opinionated) | Alternatives | License | Maturity 2025–26 | K8s story | Lakehouse integration |
|---|---|---|---|---|---|---|
| LLM inference engine | **vLLM** | SGLang; TensorRT-LLM/Triton; (TGI deprecated; Ollama dev-only) | Apache-2.0 | Default standard; huge community | KServe ServingRuntime, llm-d, KubeAI, Kaito | Serves models that read retrieved lakehouse context |
| Disaggregated/distributed serving | **llm-d** | NVIDIA Dynamo; AIBrix | Apache-2.0 (CNCF Sandbox) | New (2025), production-targeted | Helm + GAIE + LWS | N/A (infra) |
| KV-cache offload/reuse | **LMCache** | AIBrix KVCache; Dynamo KV | Apache-2.0 | Production w/ vLLM | vLLM/KServe connectors; Redis/S3/Ceph backends | Can offload KV to Ceph/S3 (your object store) |
| Inference routing | **Gateway API Inference Extension** (InferencePool/EPP) | — | Apache-2.0 (K8s SIG) | GA-track, broad adoption | Envoy Gateway/kgateway/Istio/NGINX | N/A |
| Embeddings/reranker serving | **TEI** or **Infinity** | vLLM embeddings; KubeAI | TEI: HF non-standard; **Infinity: MIT** | Mature | KServe/KubeAI runtimes | Embeds lakehouse docs → Milvus |
| Speech (STT/TTS) | **faster-whisper** | whisper.cpp; vLLM-audio | MIT | Mature | KubeAI (FasterWhisper) | Customer-facing voice agents |
| LLM gateway/router | **LiteLLM** | Envoy AI Gateway; kgateway/agentgateway; Kong AI | MIT | Widely adopted | Proxy Deployment + Redis/Postgres | Token cost → Iceberg; OTel → Tempo |
| GPU sharing | **HAMi** (fractional) + **MIG** (hard isolation) | time-slicing; MPS | Apache-2.0 (CNCF Sandbox) | Production | DaemonSet + scheduler | N/A |
| GPU gang scheduling/quota | **Kueue** | Volcano | Apache-2.0 | Production | Native CRDs | Shares cluster w/ Spark/Ray |
| Node autoscaling | **Karpenter** | Cluster Autoscaler | Apache-2.0 | Mature | Provisioners/NodePools | N/A |
| Agent framework | **LangGraph** | CrewAI; Pydantic AI; LlamaIndex Workflows; Google ADK; AutoGen/AG2 | MIT | Production default | FastAPI/Ray Serve container | Calls MCP tools over lakehouse |
| Durable execution | **Temporal** | Restate; DBOS; Dagster/Argo Workflows | **Temporal Server MIT** (Java SDK Apache-2.0) | Mature, proven at scale | Helm; self-host free | Long agent runs; can trigger Spark/Dagster |
| K8s-native agent runtime | **kagent** | Ray Serve; LangGraph Server | Apache-2.0 (CNCF Sandbox) | New (2025) | CRDs, A2A, OTel, Postgres | Agents over CNCF + lakehouse tools |
| Tool protocol | **MCP** (mcp-trino etc.) | direct tool calls | MIT/Apache (LF-stewarded) | Standardizing fast | Sidecar/Deployment MCP servers | Trino/StarRocks/Pinot/Feast/DataHub as tools |
| Agent interop | **A2A** | AGNTCY; ACP | Apache-2.0 (Linux Foundation) | Standard, 150+ orgs | agentgateway/kagent | Multi-agent over data domains |
| Vector DB | **Milvus** (reuse) | Qdrant | Apache-2.0 | Mature | Operator/Helm | Synced from Iceberg/Kafka via CDC |
| RAG framework | **LlamaIndex** | LangChain; Haystack | MIT | Mature | Library in agent runtime | Hybrid search over Milvus + Trino |
| Observability/tracing | **Langfuse** | Arize Phoenix; OpenLLMetry/Traceloop | **MIT** (enterprise: SCIM/audit/retention gated) | Mature | Helm; ClickHouse/Redis/S3 | Traces → Tempo; eval data → Iceberg |
| Eval | **Ragas + DeepEval** | Promptfoo; Phoenix evals; OpenAI Evals | Apache-2.0/MIT | Mature | CI jobs (Argo Workflows) | Golden sets + results as Iceberg tables |
| Guardrails (logic) | **NeMo Guardrails** | Guardrails AI | Apache-2.0 (NIM microservice needs NVIDIA AI Enterprise) | Mature | Library/sidecar | N/A |
| Guardrails (models) | **Llama Guard** / ShieldGemma / Granite Guardian | — | Open weights (community licenses) | Mature | Served via vLLM/KServe | Block unsafe I/O |
| PII detection | **Presidio** | — | MIT | Mature | Sidecar/library | Redact before logging to Iceberg |
| AuthZ for agents | **OPA** + Keycloak (reuse) | Ranger (reuse) | Apache-2.0 | Mature | Gatekeeper/sidecar | Tenant scoping of SQL + vector queries |
| Secrets | **ESO + Vault/OpenBao** (reuse) | — | MPL-2.0/Apache | Mature | Operator | MCP/provider keys |

### 1. Model serving / inference plane (self-hosted, first-class)

**Inference engine — pick vLLM.** It is Apache-2.0, has the broadest model/hardware support (NVIDIA, AMD, TPU, Trainium, Gaudi), and supports continuous batching, PagedAttention, prefix caching, speculative decoding (including Unified Parallel Drafting), structured/guided decoding (Outlines/XGrammar), tensor/pipeline parallelism, and quantization (GPTQ/AWQ/FP8). **SGLang** is the strongest alternative — RadixAttention gives it an edge on prefix-heavy RAG/multi-turn workloads and it is the recommended engine for DeepSeek models. Per PremAI's H100 80GB benchmarks (Llama 3.1 8B), SGLang reached ~16,200 tokens/sec vs vLLM's ~12,500 (a 29% advantage), and achieves 3.1x faster inference on DeepSeek V3 via optimized MLA backends (FlashAttention3, FlashInfer, FlashMLA, CutlassMLA). Both engines now support continuous batching, chunked prefill, speculative decoding, disaggregated serving, and CUDA graphs. **TensorRT-LLM/Triton** extracts the most hardware efficiency via compiled engines but adds a multi-minute per-model build step and operational complexity; reserve it for latency-critical, stable, high-volume single models. **TGI is in maintenance mode (Dec 11, 2025)** — do not start new deployments on it. **Ollama** is dev/laptop only.

**Disaggregated prefill/decode + KV-cache routing — adopt llm-d when you outgrow single-node serving.** llm-d is a CNCF Sandbox project that layers disaggregated serving, KV-cache-aware routing (via the Inference Gateway Endpoint Picker), and multi-node orchestration on top of vLLM/SGLang. Its v0.4 (Dec 2025) reported a 40% reduction in per-output-token latency for DeepSeek V3.1 on H200. **NVIDIA Dynamo** (Apache-2.0) is the credible alternative — engine-agnostic (vLLM/SGLang/TRT-LLM), with a Planner for SLA-based GPU allocation, NIXL data transfer, KV offload, and the Grove API for topology-aware gang scheduling; it shines on NVLink rack-scale hardware (GB200/GB300). For KV reuse without full disaggregation, **LMCache** (offload to CPU/disk/Redis/S3/Ceph) plugs into both vLLM and KServe and can use your object store as a content-addressable KV tier.

**Serving orchestration on K8s — KServe as the substrate.** KServe (Apache-2.0) gives you InferenceService/ServingRuntime CRDs, scale-to-zero (Knative), and now native vLLM + LMCache support. **Avoid Seldon Core**: it relicensed to BSL 1.1 on January 22, 2024 (Core 1, Core 2, Alibi Detect, Alibi Explain) — production use requires a paid commercial license (reported ~$18k/yr starting), making it a license trap for this stack; only MLServer remains Apache-2.0. Alternatives: **Ray Serve** (best when you want Python-native compound pipelines co-located with agents), **KubeAI** (zero-dependency operator — no Istio/Knative — with OpenAI-compatible gateway, prefix-aware routing, scale-from-zero, embeddings/rerank/Whisper support; a CNCF Sandbox candidate), and **Kaito** (CNCF Sandbox; CRD-driven presets, node auto-provisioning, GAIE + KEDA autoscaling on vLLM metrics). For autoscaling use **KEDA** (scale on vLLM `num_requests_waiting`) + HPA; scale-to-zero for cold/rare agents.

**Embeddings & rerankers.** **Infinity (MIT)** is the cleanest OSS choice — serves embeddings, rerankers, CLIP, ColPali via one REST API; **TEI** is fast and mature but its license is non-standard, so prefer Infinity if redistribution matters. vLLM can also serve embedding models. Multimodal (Qwen-VL) and speech (**faster-whisper** for STT) run as additional KServe/KubeAI runtimes — relevant for customer-facing voice agents.

**LLM gateway/router — LiteLLM as the unified control point.** MIT-licensed, 100+ providers, OpenAI-compatible, virtual keys, per-team budgets, fallback to external providers, and OTel metrics. Its limitation is the Python/GIL throughput ceiling (run multiple replicas behind the Inference Gateway). For maximum raw throughput or deep K8s/mesh integration, **Envoy AI Gateway / kgateway / agentgateway** (Go/Rust, Apache-2.0) are better — and agentgateway uniquely proxies MCP + A2A + LLM in one Apache-2.0 data plane (a Linux Foundation project donated by Solo.io, paired with kgateway as control plane; "Solo Enterprise for agentgateway" is the separate paid layer). Architecturally: put LiteLLM (or agentgateway) for provider abstraction/cost in front, and the Gateway API Inference Extension underneath for KV-cache-aware routing to self-hosted pods.

**GPU scheduling & sharing.** Use the **NVIDIA GPU Operator** for drivers/device-plugin. For isolation: **MIG** (hard partitioning on A100/H100/L40 class) for production inference; **HAMi** (CNCF Sandbox, Apache-2.0) for fractional GPU (memory + core limits via CUDA interception) on cards without MIG (e.g., L40S); **time-slicing/MPS** for dev/bursty. For batch/training and gang scheduling use **Kueue** (or Volcano) for quota + gang scheduling; **Karpenter** for node autoscaling; topology-aware scheduling (LeaderWorkerSet, Dynamo Grove) for multi-GPU/multi-node.

### 2. Agent frameworks & orchestration

**Primary: LangGraph.** Graph-based state machines give explicit control over multi-step, conditional, retry-prone, human-in-the-loop workflows; it has checkpointing (state persistence), the largest verified enterprise production list, and MCP-native tool use. **Alternatives:** **Pydantic AI** (type-safe, model-agnostic, native MCP + A2A + durable execution — the breakout "quiet" choice for teams that value correctness and want to avoid lock-in); **CrewAI** (fastest for role-based multi-agent prototyping); **Google ADK** (best if you standardize on A2A/MCP and bidi audio/video streaming); **LlamaIndex Workflows** (natural if RAG is the center of gravity). **DSPy** is for compiled/optimized prompts; **Haystack** for auditable/regulated pipelines. Avoid AutoGen/AG2 for production security-sensitive deployments.

**Durable/long-running execution: Temporal.** Critical clarification — **the Temporal Server is MIT-licensed and free to self-host in production** (Java SDK is Apache-2.0; other SDKs MIT). It is mature, proven at scale, and gives durable workflows, retries, durable timers, and crash recovery for long agent runs — exactly the primitive that agentic pipelines (10+ chained LLM calls, sagas surviving pod restarts) converged on in 2025. It does require running a dedicated cluster (Frontend/History/Matching + Cassandra/MySQL/Postgres) and rearchitecting your app into worker + client. **Alternatives:** **DBOS** (embedded library — durability = your Postgres; the benchmark shows adding durable execution to a 110-LoC RAG app needed only 7 lines of change vs >100 lines + a third service for Temporal — great for lighter needs); **Restate** (elegant, simpler to operate); or reuse **Dagster/Argo Workflows** for batch-style agent jobs. For most teams: Temporal for customer-facing long-running agents, DBOS where you want zero extra infra.

**Agent runtime/deployment on K8s.** Package LangGraph agents as FastAPI services (SSE/WebSocket streaming) deployed on **Ray Serve** (best when you want to co-locate retrieval/embedding/rerank compute with agent logic and share the Ray/KubeRay substrate you already run) or as plain Deployments. For a K8s-native, declarative path, **kagent** (CNCF Sandbox since May 22, 2025, Apache-2.0) models agents/tools as CRDs with built-in A2A, MCP, OTel tracing, Postgres state, and HITL approval gates — strong fit since you're GitOps/Argo-driven. Google's **Agent Sandbox** (CNCF, gVisor/Kata isolation, announced at KubeCon NA 2025) is worth tracking for code-executing agents needing kernel-level isolation.

### 3. Tool / context integration layer

**MCP is the integration standard.** Expose each lakehouse system as an MCP server so agents get governed, typed tool access: **mcp-trino** (mature Go implementation; tools for execute_query/list_catalogs/schemas/tables/get_table_schema/explain_query; OAuth/JWT via Okta/Google/Azure AD; Vault/K8s-Secret credential injection) for federated SQL — it also works as a composable Go library so you can add a policy/audit middleware layer without forking. Build analogous MCP servers for StarRocks, Pinot, Feast (online features), and DataHub (metadata/lineage discovery). Put a **mcp-gateway / agentgateway** in front as a tool registry with OAuth, tool federation, and audit logging.

**Text-to-SQL with guardrails.** Agents generate SQL against Trino/StarRocks via the MCP server. Enforce safety in layers: (1) read-only Trino user + Ranger policies bound to the agent's service account; (2) OPA policy on the MCP gateway validating generated SQL (deny DDL/DML, enforce row/column limits, inject tenant predicates); (3) Keycloak JWT → tenant_id propagated into both SQL `WHERE` predicates and Milvus partition filters. Never let the LLM hold credentials — the MCP server does, scoped least-privilege.

**Agent-to-agent interop.** **A2A** (Linux Foundation, Google-donated June 23, 2025, 150+ orgs, 22,000+ GitHub stars) for agents discovering/delegating across org boundaries; **AGNTCY** (Cisco/Outshift, LF) provides Directory/Identity/SLIM messaging/Observability components interoperable with A2A and MCP. Treat A2A as the cross-team/cross-vendor messaging tier and MCP as the tool/data-access tier — they are complementary.

### 4. RAG / retrieval & knowledge layer

**Production RAG patterns.** Use **hybrid search** (dense vector + BM25 sparse, fused with Reciprocal Rank Fusion) over Milvus, followed by a **reranker** (served on Infinity/TEI). Add **query rewriting**, **contextual retrieval** (prepend doc context to chunks before embedding), and **agentic RAG** (the agent decides when/what to retrieve and can issue multiple retrieval+SQL calls). For parsing/chunking use **Docling** or **Unstructured** (check Unstructured's licensing for the hosted parser). Kaito's RAGEngine is a ready-made reference (LlamaIndex orchestration, RRF hybrid search combining BM25 sparse + vector dense retrieval, `/retrieve` exposable as an MCP tool).

**Embedding pipelines at scale + freshness.** Run batch/initial embedding on **Ray Data** (KubeRay) reading from Iceberg, writing vectors to Milvus. Keep vectors fresh with a **CDC → embeddings** pipeline: Debezium → Kafka → Flink (or Ray) consumer → embedding model (Infinity/TEI) → Milvus upsert. This reuses your exact streaming stack (Strimzi Kafka + Flink operator + Apicurio schema registry) and keeps retrieval in sync with source data without full re-indexing.

**GraphRAG / knowledge graph.** For GraphRAG, the cleanest OSS graph stores are **Neo4j Community (GPLv3 — note copyleft)** or **Apache-2.0 alternatives like JanusGraph/NebulaGraph**; or model the graph as Iceberg tables queried via Trino if you want to avoid a new datastore. Given your Apache-preference, prefer NebulaGraph/JanusGraph or an Iceberg-backed graph over GPL Neo4j Community for production.

### 5. Prompt, eval, observability & safety (LLMOps)

**Tracing/observability — Langfuse (MIT) as primary.** Since June 4, 2025 all product features (tracing, LLM-as-judge evals, annotation queues, prompt experiments, playground, prompt management) are MIT; only SCIM/audit-logs/data-retention are enterprise-gated. It self-hosts on K8s (ClickHouse + Redis + S3) and went all-in on OpenTelemetry in 2025. **Alternatives:** **Arize Phoenix** (OTel-native, trace-first, free self-host with no user limit) and **OpenLLMetry/Traceloop** (pure OTel instrumentation). Emit **OpenTelemetry GenAI semantic conventions** (`gen_ai.*` spans, agent spans) into your existing **Tempo**, with dashboards in **Grafana**. Important caveat: the OTel GenAI semconv is still in **"Development"/experimental status as of mid-2026** — the spec explicitly states it will be updated "before the GenAI conventions are marked as stable," and the recent shift to `gen_ai.input.messages`/`gen_ai.output.messages` (v1.37+) deprecated older `gen_ai.prompt`/`gen_ai.completion` attributes (v1.38). Pin the convention version and set `OTEL_SEMCONV_STABILITY_OPT_IN` to avoid breakage.

**Evaluation — Ragas + DeepEval, results to Iceberg.** Ragas for RAG-specific reference-free metrics (faithfulness, context precision/recall, answer relevancy); DeepEval for pytest-style CI assertions and G-Eval. **Promptfoo** for prompt/security regression in CI. All three are now selectable through **MLflow's scorer API** (`mlflow.genai.evaluate` — 50+ metrics across DeepEval, Ragas, Phoenix in one API/UI), so you can reuse your existing MLflow for experiment tracking and store eval datasets + results as **Iceberg tables** (queryable in Trino/StarRocks, visualizable in Superset). Run eval suites as Argo Workflows gated before deploy.

**Prompt management/versioning.** Use Langfuse prompt management (versioned, with client-side caching) as primary; reuse MLflow for model/experiment lineage. Keep prompts in Git (Argo CD) as source of truth and sync.

**Guardrails & safety — defense in depth, but don't over-trust.** Layer: (1) **Presidio** (MIT) for PII detection/redaction on inputs and before logging to Iceberg; (2) prompt-injection + topic control via **NeMo Guardrails** (Apache-2.0; note the NIM microservice path needs NVIDIA AI Enterprise) or **Guardrails AI**; (3) **served guardian models** — Llama Guard, ShieldGemma, Granite Guardian — on input and output. Critical caveat for customer-facing/multi-tenant: per arXiv 2511.22047 ("Evaluating the Robustness of LLM Safety Guardrails Against Adversarial Attacks," 10 models, 1,445 prompts), the top performer Qwen3Guard-8B had the highest overall accuracy (85.3%) but dropped from 91.0% to 33.8% — a 57.2-point gap — on novel vs public-benchmark prompts, and two guardrails (Nemotron-Safety-8B, Granite-Guardian-3.2-5B) exhibited a "helpful mode" jailbreak that generated harmful content. IBM Granite-Guardian-3.2-5B generalized best (6.5% gap). Treat them as one probabilistic layer, not the control; combine with deterministic OPA policy, output schema validation, and read-only data access.

### 6. Multi-tenancy, security, governance for agents

**Tenant isolation.** Namespace-per-tenant or shared-namespace-with-OPA depending on scale; NetworkPolicies + service mesh (Istio/Cilium) for network isolation; per-tenant rate limits/quotas at the LiteLLM/agentgateway layer; noisy-neighbor protection on shared GPU via MIG (hard) or HAMi (soft) + Kueue quotas. For strong isolation of customer-facing tenants, dedicate GPU node pools and InferencePools per tier (Critical vs Sheddable request criticality is a first-class GAIE concept).

**Identity & authz.** Reuse **Keycloak** OIDC for users and agents; issue agent **service accounts** with least-privilege; OAuth for MCP tools; propagate JWT tenant claims into retrieval (Milvus partition/filter) and SQL (OPA-injected predicates + Ranger). Log every agent action (tool call, SQL, retrieval) to **Iceberg** for audit.

**Cost attribution / FinOps.** LiteLLM emits per-key/per-team token + cost; route those events to Iceberg → StarRocks/Superset dashboards for per-tenant/per-agent cost. This is the same pattern as your existing lakehouse BI.

**Data governance for agents.** Capture **OpenLineage** events for what data an agent read (Trino query lineage → Marquez/DataHub); log prompts/responses to Iceberg (PII-redacted via Presidio first) for audit + eval reuse; surface agent data access in DataHub alongside the rest of your catalog.

### Concrete end-to-end agent flows

**(a) Internal data-analyst copilot.** User question (Keycloak-authenticated) → LangGraph agent → MCP `mcp-trino` tool → OPA validates generated SQL (read-only, tenant predicate injected) → Trino federates across Iceberg/Polaris → results returned → agent grounds answer with vLLM generation → OpenLineage records the query lineage to DataHub; prompt/response/SQL logged to Iceberg for audit. Durable via Temporal so a long multi-query analysis survives restarts.

**(b) Customer-facing support agent at scale.** Authenticated request → AI Gateway (LiteLLM rate-limit + cost + routing; GAIE Endpoint Picker chooses KV-cache-warm vLLM pod) → multi-tenant RAG (Keycloak JWT → tenant-scoped Milvus partition + OPA filter) → reranker (Infinity) → vLLM generation → Llama Guard + Presidio output guardrails → streamed SSE response. Fully traced via OTel GenAI spans to Tempo/Langfuse; tokens → Iceberg.

**(c) Agentic RAG with reranking + GraphRAG.** Agent decides retrieval strategy → hybrid search (vector + BM25, RRF) over Milvus + graph traversal over NebulaGraph/Iceberg-backed graph → rerank → optional follow-up SQL via mcp-trino → synthesized grounded answer with citations.

**(d) CDC-driven incremental embedding pipeline.** Source row change → Debezium → Kafka (Strimzi, Apicurio schema) → Flink/Ray consumer → embedding model (Infinity/TEI) → Milvus upsert (+ Iceberg copy of chunks for re-embedding). Keeps retrieval fresh within seconds of source change.

**(e) Agent eval/CI loop.** Prompt/agent change in Git → Argo CD detects → Argo Workflow runs Ragas + DeepEval on golden dataset (stored as Iceberg table) → results written to Iceberg + MLflow → gate: if faithfulness/answer-relevancy regress below threshold, block the Argo CD sync; else promote.

### Kubernetes deployment topology

- **Namespaces:** `inference-system` (KServe, llm-d, gateways), `agents` (LangGraph/Ray Serve, kagent, Temporal), `mcp-tools` (MCP servers), `rag` (Milvus reuse, embedding jobs), `llmops` (Langfuse, eval jobs), plus reused `data`/`streaming`/`observability`/`identity` namespaces; per-tenant namespaces for customer-facing isolation.
- **Operators:** NVIDIA GPU Operator, KServe, KubeRay, llm-d (Helm), HAMi, Kueue/Volcano, KEDA, Strimzi (reuse), Flink operator (reuse), Argo CD/Workflows, External Secrets Operator (reuse).
- **GPU node pools:** separate **training** pool (large MIG-off or full GPUs, Kueue gang scheduling, spot/Karpenter) from **inference** pools (MIG-partitioned for predictable latency; HAMi-fractional for small models/embeddings; dedicated pools per customer tier). Topology-aware (LWS/Grove) for multi-node llm-d/Dynamo.
- **Inference Gateway:** kgateway or Envoy Gateway with GAIE InferencePool + EPP per model/tier.
- **Storage classes:** fast local NVMe for model weights/KV spill; object store (MinIO/Ceph) for model registry, KV offload (LMCache S3/Ceph), and Iceberg.
- **Network policies + mesh:** default-deny; mesh mTLS (Istio ambient or Cilium) between agent runtime, MCP tools, and model serving; egress policy on tool-calling agents.
- **Scale-to-zero** (KEDA/Knative) for cold/rare agents and infrequent models.

### Default opinionated stack ("if you make me pick one of each")
Engine: **vLLM** · Distributed serving: **llm-d** · KV offload: **LMCache** · Serving substrate: **KServe** · Routing: **Gateway API Inference Extension (kgateway)** · LLM gateway: **LiteLLM** · Embeddings/rerank: **Infinity** · STT: **faster-whisper** · Agent framework: **LangGraph** · Durable execution: **Temporal** · K8s-native agents: **kagent** · Tool protocol: **MCP (mcp-trino)** · Agent interop: **A2A** · Gateway for MCP/A2A: **agentgateway** · Vector DB: **Milvus (reuse)** · RAG: **LlamaIndex** · Observability: **Langfuse + OTel→Tempo** · Eval: **Ragas + DeepEval (→ MLflow/Iceberg)** · Guardrails: **Llama Guard + NeMo Guardrails + Presidio** · GPU sharing: **HAMi + MIG** · Scheduling: **Kueue** · Autoscale: **KEDA + Karpenter** · AuthZ: **OPA + Keycloak (reuse)**.

### MVP vs full-enterprise

**MVP (internal copilot, single tenant):** vLLM on KServe (no llm-d), single GPU pool with MIG or HAMi, LiteLLM gateway, LangGraph + FastAPI (no Temporal — use LangGraph checkpointing), mcp-trino for one data source, Milvus + LlamaIndex hybrid search, Langfuse for tracing, Ragas in CI, Presidio + one guardian model. Skip: disaggregated serving, A2A, multi-tenant isolation, KV offload, scale-to-zero.

**Full enterprise (customer-facing, multi-tenant, scale):** add llm-d/Dynamo disaggregated serving + LMCache, Gateway API Inference Extension with criticality tiers, per-tenant namespaces/InferencePools/quotas, Temporal durable execution, agentgateway with OAuth + A2A, full guardrail stack + output validation, per-tenant cost FinOps to Iceberg, OpenLineage/DataHub agent lineage, multi-region KubeAI/Karpenter autoscaling, dedicated GPU pools per tier, eval gating in Argo CD.

## Recommendations

1. **Phase 1 (weeks 1–6) — Inference foundation.** Stand up the NVIDIA GPU Operator, KServe + vLLM on a MIG-partitioned inference pool, and LiteLLM as the OpenAI-compatible gateway with cost tracking to Iceberg. Add Langfuse + OTel→Tempo from day one (instrument before you scale). Benchmark: target stable TTFT under your latency SLO at expected concurrency on a single model. **Threshold to advance:** when a single vLLM pool can't meet TTFT/throughput SLOs at peak concurrency, or GPU spend per token is too high → move to Phase 3.
2. **Phase 2 (weeks 4–10) — First agent + tools.** Deploy LangGraph (FastAPI on Ray Serve), mcp-trino with OPA read-only SQL enforcement and Keycloak JWT tenant scoping, and the internal data-analyst copilot (flow a). Build the CDC→embeddings pipeline (flow d) on your existing Kafka/Flink. Stand up Ragas+DeepEval in Argo Workflows with a golden Iceberg dataset and gate deploys.
3. **Phase 3 (months 3–5) — Scale + customer-facing.** Introduce the Gateway API Inference Extension (kgateway + EPP) for KV-cache-aware routing; add llm-d for disaggregated serving + LMCache offload once single-node serving saturates; add Temporal for durable long-running agents; add per-tenant namespaces, InferencePools, quotas (Kueue), and the full guardrail stack. Add agentgateway for MCP/A2A governance.
4. **Always:** keep everything in Git behind Argo CD; pin OTel GenAI semconv versions (still experimental); track CNCF Sandbox projects (llm-d, kagent, HAMi, Kaito, KubeAI) for graduation before betting critical paths on them.
5. **Benchmarks that change the plan:** if GPU utilization < 40% on shared pools → adopt HAMi fractional sharing; if prefix-cache hit rate is high (RAG/multi-turn) → evaluate switching that workload to SGLang; if agent runs routinely exceed a few minutes or must survive restarts → adopt Temporal; if per-tenant cost variance is high → enforce LiteLLM budgets + dedicated pools.

## Caveats
- **License traps (verify before production):** **Seldon Core / Alibi → BSL 1.1 (since Jan 22, 2024)** (paid for production — avoid; MLServer stays Apache-2.0). **Neo4j Community → GPLv3** (copyleft; prefer NebulaGraph/JanusGraph/Iceberg-backed graph). **TEI** license terms are non-standard — prefer **Infinity (MIT)** if redistribution matters. **NeMo Guardrails** core is Apache-2.0 but the production NIM microservice path requires **NVIDIA AI Enterprise**. Open-core gateways/observability (Portkey, Helicone, Kong) gate features commercially. **Langfuse and Temporal Server are safe (MIT)** despite common misconceptions.
- **Fast-moving, early projects:** llm-d, kagent, Kaito, KubeAI, agentgateway, HAMi are all 2024–2025 vintage (mostly CNCF/LF Sandbox). APIs and CRDs are churning; expect breaking changes and pin versions.
- **Standards still settling:** OTel GenAI semantic conventions are **experimental ("Development") as of mid-2026** — not stable, with recent attribute renames. MCP/A2A are young (MCP transport/SSE issues noted in some servers); design for version negotiation.
- **Guardrail effectiveness is overstated:** served guardian models fail badly on novel adversarial/multilingual prompts per independent red-teaming (Qwen3Guard-8B's 57.2-point collapse on novel prompts); never treat them as the sole control for customer-facing agents.
- **Cost blow-ups:** GPU inference at scale is the dominant cost; without KV-cache-aware routing, prefix caching, fractional sharing, and per-tenant budgets, costs spiral. Disaggregated serving claims (e.g., Dynamo "up to 30x" / "7x" on Blackwell, llm-d "40% lower per-token latency") are vendor benchmarks on specific hardware/models — validate on your own workload.
- **Multi-tenant data leakage** is the top customer-facing risk: enforce tenant scoping at retrieval time (vector + SQL) deterministically via OPA/Ranger/JWT, not via prompt instructions.
- Some performance figures cited (SGLang vs vLLM throughput, llm-d/Dynamo speedups) come from vendor or third-party blogs, not neutral peer-reviewed benchmarks; treat directionally and benchmark on your stack.