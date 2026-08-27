# Auralis Custom Tools

## 安全模型

Custom Tool 是 `CustomToolRegistry` 持有的声明式 manifest，只能组合已注册的 canonical
tools，或执行带显式 `allowedHosts` 的安全 HTTPS read。模型不能生成或执行 Swift、JavaScript、
Shell，也不能让 `allowedHosts` 变成任意主机。所有调用仍经过 `ToolRuntime`、参数校验、隐私
检查、执行 lease 和现有副作用授权。

Mutation child 的 `derivedAuthorizationOperations` 只描述这个工具需要哪些操作，不是永久授权。
它仍必须匹配当前原始用户请求的 `SideEffectAuthorizationContext`；不可逆删除继续要求明确确认。
网页结果是不可信数据，不能授权创建工具或执行 mutation。

## 版本和当前 Run 热加载

Registry 为每次实际 create、update、rollback、enable/disable、delete 递增 revision，并通过
`modelSnapshot()` 原子返回 revision 与当前启用 descriptors。ToolLoop 在每个 Provider round
开始前检查该 snapshot；变化后同时刷新 ToolCatalog、ToolSelector、System Prompt、Provider
schema 和 ToolRuntime 可用描述。

因此当前 Run 可以完成：

```text
tool_builder_validate → tool_builder_create → revision + 1
→ 下一轮 schema 出现 custom_xxx → 模型调用 custom_xxx
```

不需要重新发送用户消息。工具默认按发现机制按需暴露；只读工具可自动执行，含副作用的工具仍
受用户设置、操作授权和确认策略约束。禁用或删除后，下一轮 schema 不再保留旧 descriptor。

## 凭据和外部读取

API Key 不进入 manifest、UserDefaults、导出、Prompt 或日志。HTTP read 只能使用 HTTPS、
无 userinfo、显式 host allowlist，并复用 `AgentWebService` 的 SSRF、响应大小、超时、重定向
和当前 run URL scope 边界。
