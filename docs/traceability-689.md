# DPI-I-689: native AI investigation traces

This implements [DPI-I-689](https://ideas.intersystems.com/ideas/DPI-I-689) using actual InterSystems Interoperability messages. It is not an awarded-points claim. The Idea is also linked in both READMEs; the application's Open Exchange dedicated Idea association and organizer review are separate publication steps.

## Runtime

The existing isolated investigation job enters `PI.Trace.Intake.ProcessInput` → `InvestigationWorker` (an InProc `PI.Trace.Worker`). The original SDK loop runs in `PI.Agent.WorkerCore` inside that native owner. The worker sends typed `PI.Trace.Event` requests to `ModelTrace`, `ToolTrace` and `RunTrace`. Native session and request-header IDs identify the real parent; trace/span IDs give model/tool hierarchy within that session. Original case, source, policy, budget, daily limits, evidence validation, human review and Java PEX behavior remain in force.

Build154 invokes its agent loop through Rust provider tokens, bypassing ObjectScript `Provider.ChatComplete` overrides. A run-scoped loopback HTTP observer therefore forwards requests to the already configured upstream. Each actual OpenAI-compatible (including Qwen/Ollama), Anthropic or NIM attempt produces sanitized request/response metadata, including failures. It adds no model retry or fallback. Identical requests following an observed failure are labeled `identical-after-failure`, without guessing SDK intent. The existing invalid-JSON repair is separately labeled `application-json-repair`, links `sdk-2` to `sdk-1`, and uses `PromptVersion=pi-json-repair-v1`; normal investigation instructions use `pi-agent-v1`. Prompt-version constants must be advanced when the corresponding instructions change.

Google Gemini's native adapter has no endpoint override in this build. Its original behavior is preserved and `Coverage=sdk-invocation-only` explicitly limits visibility to SDK boundaries, tools and available aggregate statistics; per-HTTP Google attempts/retries are not claimed.

New messages have no arbitrary payload, prompt, completion, tool arguments/results, HTTP headers, upstream URL/query, credential or external exception-text field. Observer configuration passes through private pipes; original request/response bodies stay in RAM. The child binds only `127.0.0.1`, uses separate random data/control paths, verifies HTTPS upstreams, preserves bounded retry headers, rejects redirects/streaming, caps body/event sizes, and exits on close, parent exit or a bounded lease. Upstream connect/TLS is capped at ten seconds and request/read at the existing 110-second timeout. No telemetry goes to an external service. The existing persisted AI Hub sessions are unchanged; new telemetry does not copy their transcripts.

**Timing:** Embedded Python reentry from an SDK tool callback crashes the tested build. Callbacks consequently buffer sanitized metadata only in ObjectScript RAM. After `Chat` returns or throws, the owner merges observed HTTP/tool timestamps and persists native child messages. Header timestamps are emission times; payload `StartedAt`, `EndedAt`, `DurationMs` are actual observation times. This is not live streaming of an unfinished call. A forced job/container termination before the drain can leave only the start events and lose buffered observations; an unfinished trace must not be interpreted as complete. Existing investigation timeout handling remains authoritative and clears its private candidate keys.

Missing token values stay absent with `UsageKnown=0`. When complete observed usage and configured planning prices exist, `EstimatedCostUsd` is explicitly an estimate (`CostBasis=configured-planning-rate`), not an invoice. Otherwise `CostKnown=0`; unknown usage is never converted to free usage. Sum HTTP `model.response` rows when analyzing attempts; SDK rows are aggregates and must not be added to their child totals.

The SDK result and diagnostic run record stay under private candidate keys until final trace acknowledgement and relay cleanup finish. Only then are the public run record and polled completion key published. A tracing failure withholds the recommendation, preserves actual invocation/accounting information, and produces `TRACE_FAILED`. It does not approve or modify an identity mapping. Tool IDs are monotonic for the whole run, including JSON repair, and observation buffers are bounded.

## Reproduce without a paid model

Use Docker and the supported AI Hub image:

```sh
bash scripts/trace-smoke.sh
python3 -m unittest discover -s tests -p test_trace_relay.py -v
```

The smoke script creates a fresh container with no external network and no existing data volume. A synthetic loopback model drives the actual native SDK through two HTTP calls and two actual native tools. Tests verify 52 input/20 output tokens, actual `Ens.MessageHeader` parent/session linkage, privacy sentinels, HTTP failure, explicit unknown usage, concurrent isolation and two SDK phases without repeated tool IDs. Synthetic model responses validate instrumentation and contracts, not a real-provider account or medical/identity decisions.

For a fully bootstrapped disposable Compose instance, `scripts/test.sh` runs the existing application regressions plus the schema check. The additional publication regression uses the actual `PI.Agent.Worker` and a test-only final-ACK gate:

```sh
PI_TRACE_FULL_CONTAINER=pi-689-full python3 -m unittest discover \
  -s tests -p test_trace_publication.py -v
```

That container must be fresh, contain `/workspace`, have `PITEST` initialized, and use only test configuration. The gate proves neither completion nor diagnostic history is visible while the final native ACK is pending; rejection must not publish success. It is never configured in `PI.Production`.

In the namespace that executed the investigation, select a row from `PI_Trace.Event` and open `NativeSessionId` in Management Portal → Interoperability → Visual Trace:

```sql
SELECT ID, TraceId, RunId, CaseId, CaseVersion,
       NativeSessionId, NativeParentMessageId, SdkInvocationId, SdkSessionId,
       Kind, SpanId, ParentSpanId, Sequence, AttemptSequence,
       PromptVersion, TraceMode, Provider, Model,
       StartedAt, EndedAt, DurationMs, HttpStatus, Status, ErrorCode,
       UsageKnown, InputTokens, OutputTokens,
       CostKnown, EstimatedCostUsd, CostBasis,
       ToolName, Coverage, RetryOf, RetryKind, Fallback
FROM PI_Trace.Event ORDER BY ID DESC;

SELECT ID, SessionId, SourceConfigName, TargetConfigName,
       MessageBodyClassName, MessageBodyId, CorrespondingMessageId,
       TimeCreated, TimeProcessed, Status
FROM Ens.MessageHeader WHERE SessionId = <NativeSessionId> ORDER BY ID;
```

`Sequence` is emission order, `AttemptSequence` is the observed HTTP attempt number (`http-N`). Tool `ParentSpanId` binds to the model response requesting it; native headers remain real children of `InvestigationWorker`. Existing run APIs include `traceId`, `nativeSessionId` and `traceCoverage` after final acceptance. The fixture labels all observations `TraceMode=synthetic`.

## Compared with Langfuse

IRIS keeps application routing, SDK invocation, actual request/tool metadata and run outcome in one locally inspectable Production session without another telemetry store. [Langfuse](https://langfuse.com/docs) offers broader prompt/evaluation, datasets and cross-service workflows; this implementation does not reproduce them or claim feature parity. Raw prompt/completion inspection, Google HTTP internals, live streaming, and crash-proof buffering are explicit limits.

## 中文说明

本功能对应 [DPI-I-689](https://ideas.intersystems.com/ideas/DPI-I-689)。真实调查作业进入原生 `InvestigationTrace → InvestigationWorker`，在同一 `SessionId` 内生成模型、工具和运行阶段的类型化消息。姓名比较仍使用原 Java PEX；版本保护、日额度、预算、证据校验及人工决定保持原有流程。

OpenAI 兼容协议、Qwen、Ollama、Anthropic、NIM 通过仅监听本机的临时观察进程访问原配置上游，不新增重试和回退。Gemini 保留原 SDK 行为并明确标注“仅 SDK 调用级”，不声称记录了其每次 HTTP。工具回调只缓存受控元数据，SDK 返回后再合并写入原生消息；载荷时间代表实际调用，消息头时间代表生成消息的时间。强制中断可能丢失尚未合并的观察记录，不能把不完整追踪当成成功完成。

新增消息不存提示词、模型正文、工具参数/结果、密钥或异常原文。未知 token/费用明确标记未知；配置价格计算的费用仅为估算，不代表账单。现有 SDK 会话保存方式没有改变。模型候选结果和运行历史在最终追踪确认、观察进程清理完成前保持私有；失败时不会先发布成功建议。

上方独立容器命令使用合成模型服务运行真实 SDK、真实工具及真实原生消息，验证用量、失败、隐私、并发隔离、跨阶段工具 ID 和消息父子关联。按 SQL 找到实际命名空间中的 `NativeSessionId` 后打开原生 Visual Trace。此实现说明不代表已提交 Open Exchange 专门关联或已获得比赛加分。
