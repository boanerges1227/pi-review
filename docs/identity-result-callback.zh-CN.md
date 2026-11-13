# 审核结果回传：Custom Outbound Adapter

人工执行关联（LINK）、独立建档（SEPARATE）、拒绝（REJECT）或撤销（UNDO）时，系统在修改审核记录和身份映射的同一 IRIS 事务中保存不可变回传事件。提交后，通过 `IdentityResultRelay` → `IdentityResultOutbound` → `PI.Adapter.IdentityResultOutbound` 异步发送。自定义适配器继承 `EnsLib.HTTP.OutboundAdapter`，负责结果协议、幂等请求头及回执校验。

审核入口自行管理最终提交，调用者已有活动事务时拒绝执行（`REVIEW_TRANSACTION_UNSUPPORTED`）。Relay 领取事件时短暂共享审核锁，避免通过原始全局数据读到尚未提交的事件；网络请求在释放该锁后执行。

随项目提供的是模拟 HIS 接收端。验证使用真实 Production 和 HTTP 请求，但不代表已经连接真实医院或完成院方验收。

## 配置启用

`PI.Production` 中两个新增组件**默认关闭**，不预设外部服务器。安装或重新加载更新后的类，在正常维护窗口更新 Production 配置；应用新定义前核对已有配置。

1. 在原生 Production 门户配置 `IdentityResultOutbound` 的适配器参数：`HTTPServer`、`HTTPPort`、`URL`（默认 `/identity-results`）。需要认证时配置命名 IRIS `Credentials`；HTTPS 使用 `SSLConfig` 并保留服务器身份校验。接收端须支持下文回执协议。
2. `ConnectTimeout`、`ResponseTimeout` 与 `WriteTimeout` 须为正数，合计不超过 45 秒，默认分别为 5、10 和 5 秒，以确保网络请求在 60 秒队列租约内结束；不跟随重定向。
3. 操作组件参数 `MaxAttempts` 默认 3，范围 1–20；`RetrySeconds` 默认 5 秒，范围 1–3600。Relay 适配器的 `CallInterval` 默认 5 秒。
4. 先启用出站组件，再启用 Relay 并应用配置。暂停时先停 Relay；已入队或发送中的事件仍可能完成。停用出站组件会暂停其原生队列，不会撤销已提交的审核。

关闭期间创建的待发送事件会在启用后发送。历史 `simulated=true` 通知保留，不自动补发。真实 HIS 的协议和认证可能需要单独适配，这里不宣称通用医院接口兼容。

## 消息和回执协议

请求为 `POST /identity-results`，`Content-Type: application/json`，`Idempotency-Key` 与 `eventId` 相同。

```json
{
  "schemaVersion": 1,
  "eventId": "pi-<globally-unique-id>",
  "caseId": "c1",
  "caseVersion": 2,
  "sourceSystem": "HIS",
  "sourcePatientId": "synthetic-p1",
  "sourceVersion": 1,
  "kind": "APPROVAL",
  "action": "LINK",
  "previousMasterId": "",
  "masterId": "m1",
  "occurredAt": "2026-11-13T00:00:00Z"
}
```

UNDO 使用 `kind=CORRECTION`，其他动作为 `APPROVAL`。REJECT 回传保持不变的映射（允许为空），UNDO 回传恢复后的映射。来源标识对应被审核记录，`caseVersion` 为决策后的版本。不发送姓名、出生日期、证件号码、模型证据或审核自由文本。

成功须为 HTTP **200 或 201**，并返回不超过 8192 字节的 JSON 对象：

```json
{"eventId":"pi-<same-id>","status":"ACCEPTED","receiptId":"his-<stable-receipt>"}
```

同一事件重复送达时，返回 `status=DUPLICATE` 和首次的回执 ID。接收端必须按事件 ID 持久化去重；同一 ID 对应不同内容须拒绝。仅 HTTP 成功不足以标记 SENT：事件 ID 不匹配、缺失回执 ID、格式错误或状态不符都算失败。系统只保存这三个协议回执字段。

## 重试、顺序与恢复

- 状态为 `PENDING` → `QUEUED` → `SENT`；失败后进入 `RETRY`，达到本轮 `MaxAttempts` 后进入 `FAILED`。所有投递失败都采用有上限的统一重试策略。`attempts` 保留累计次数，手动恢复仅重置本轮计数。
- 持久化待发送事件避免审核已提交但尚未入队时丢失。Relay 每次轮询最多检查 100 项，并保存轮转游标。未完成的队列租约 60 秒后可重新领取；重启后的轮询会恢复发送。重复队列项遇到已发送事件直接跳过。
- 同一来源系统、患者记录的事件按前后关系发送。撤销等后续事件必须等待前一事件 SENT；如果前一事件重试耗尽，需要先恢复它，后续事件才会继续。
- 网络请求仅持有通知级锁，不占用审核事务锁。HIS 不可用不会回滚审核。接收成功但回执丢失时，重发同一事件 ID 和内容，由接收端去重。这是**至少一次投递加接收端去重**，不是跨系统的严格恰好一次事务。
- 管理员可查看 `^PIData($namespace,"notification",id)` 及案例的 `NOTIFICATION_*` 审计记录。`lastError=HIS_DELIVERY_FAILED` 为受控错误码，不把远端响应正文写入审计。原生 Production 追踪可关联通知请求 ID。
- 修复地址或接收端问题后，在应用命名空间手动恢复耗尽的事件：

```objectscript
do ##class(PI.Route).Notify("n1")
```

请在没有活动事务的上下文执行恢复。重新打开事件、恢复待发送索引和写入审计在同一事务中完成，保留原事件 ID、内容和累计次数。已发送事件和历史模拟通知不会被重发。如果工作进程在记录最后一次尝试后中断，恢复时标记 FAILED（`HIS_ATTEMPTS_EXHAUSTED`），不突破次数上限；管理员可使用相同事件 ID 显式重新打开这类结果不确定的事件。本轮不增加公开的 HTTP 重试接口。

## 一键验证

```bash
bash scripts/notification-smoke.sh
```

脚本使用本地 AI Hub 镜像（可通过 `IRIS_IMAGE` 指定），创建全新 `--network none` 容器，以只读方式挂载源码，在容器回环地址 18894 端口启动模拟 HIS，编译源码并运行真实 Production 测试，最后删除临时容器。不公开端口、不挂载原业务卷、不使用模型密钥。日志保存在已忽略的 `artifacts/notification-smoke/`。

`tests/mock_his.py` 使用 SQLite 事务实现持久化和并发去重。`/__test/control`、`/__test/state` 仅供测试；不能将模拟接收端公开或作为正式 HIS 使用。

测试覆盖匹配回执、四类人工动作、失败重试、耗尽后恢复、回执丢失及错误回执、并发重复请求、接收端重启、事务回滚和 Production 重启及过期租约恢复。
