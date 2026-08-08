# Metadata Strategy

## 来源优先级

1. 原始文件与服务器元数据；
2. MusicBrainz；
3. Cover Art Archive；
4. 用户手工信息；
5. AI 推断。

MusicBrainz 客户端必须设置可识别 User-Agent，默认平均不超过每秒一次请求。Cover Art
Archive 只通过 MBID 查询；封面仍受各权利人版权约束，不能自动进入 Demo 或分发包。

## Overlay

第一阶段修改只存于客户端 `MetadataOverlay`。`MetadataMerge` 仅替换非空显式字段；原 Track
保持不可变，接受、拒绝、批量接受、撤销与恢复原始值都写审计日志。AI 候选包含 value、
confidence、source、reason 和 requiresUserReview。

## NAS Companion 协议

`MetadataAgent` 只定义 preview/apply/rollback。未来服务必须提供只读预览、备份、原子替换、
修改日志与 Navidrome 重扫。客户端绝不把 OpenSubsonic 读 API 当成安全标签写入接口。
