# Privacy Model

## 默认拒绝

默认不发送音频、完整路径、NAS 地址、用户名、服务器 Token、API Key、完整歌词、设备标识
和原始日志。Demo 模式不发起任何 AI 或服务器网络请求。

## 用户权限矩阵

歌曲元数据和分类标签可单独允许；歌词、播放历史、收藏评分与库外发现默认关闭。每次请求前
展示字段列表、Provider、模型、Token 估算、是否含歌词与预计目的，用户可取消。

## Secret 生命周期

- 源码和配置只保存 `CredentialID`；
- 生产凭据存于 Keychain，不存 UserDefaults/数据库；
- OSLog 只记录请求类别、耗时和脱敏错误；
- 自签证书只允许显式 Debug 配置，Release 默认拒绝；
- 导出 AI 数据不包含 Keychain 值、认证 Header 或服务器私有地址。

## 删除

用户可以清空对话、分类、Metadata Overlay、推荐反馈或全部 AI 数据。关闭 AI 后 Provider
不会创建网络任务，基础播放与资料库保持完整可用。
