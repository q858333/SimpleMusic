# SimpleMusic Worker D1 设备注册设计

日期：2026-08-24
状态：已确认

## 目标

在 SimpleMusic 仓库中新建独立的 `worker/` TypeScript 项目，通过 Cloudflare Worker 提供设备注册 HTTP 接口，并使用 D1 保存设备号及 APNs Token。首阶段只完成 Worker、数据库 migration 和本地 D1 集成测试，不修改 iOS 自动上报、不部署 Worker，也不写入远程 D1。

## 范围

本阶段包含：

- 创建原生 Cloudflare Worker TypeScript 项目。
- 将现有 Cloudflare D1 数据库绑定为 `DB`。
- 添加首个 `devices` 表 migration。
- 实现 `POST /api/v1/devices/register`。
- 使用 Cloudflare Workers Vitest 集成环境和隔离的本地 D1 验证接口及 SQL 行为。

本阶段不包含：

- iOS 端网络请求或自动上报。
- 远程 Worker 部署或远程 D1 migration。
- APNs 推送发送服务。
- 用户账号、登录、鉴权、音乐数据或下载记录。

## 项目结构

Worker 子项目固定放在仓库的 `worker/`：

```text
worker/
├── migrations/0001_create_devices.sql
├── src/index.ts
├── test/device-registration.spec.ts
├── package.json
├── package-lock.json
├── tsconfig.json
├── vitest.config.ts
└── wrangler.jsonc
```

使用原生 Worker 和 D1 API，不引入 Hono、ORM 或额外路由框架。D1 binding 名称固定为 `DB`。实施时通过已登录的 Wrangler 读取用户现有 D1 数据库信息并写入配置；测试始终使用隔离的本地 D1，不连接或修改远程数据。

## HTTP 接口

### 请求

```http
POST /api/v1/devices/register
Content-Type: application/json
```

请求体：

```json
{
  "deviceId": "11111111-2222-3333-4444-555555555555",
  "apnsToken": null,
  "apnsEnvironment": null,
  "appVersion": "1.0.0",
  "systemVersion": "18.0",
  "deviceModel": "iPhone"
}
```

字段规则：

- `deviceId` 必填，必须是合法 UUID 字符串，最大 36 个字符。
- `apnsToken` 可缺省或为 `null`。存在时必须是十六进制字符串，不假设 Apple Token 的固定字节长度，最大 512 个字符。
- `apnsEnvironment` 在 `apnsToken` 存在时必填，只允许 `development` 或 `production`；没有 Token 时必须缺省或为 `null`。
- `appVersion`、`systemVersion`、`deviceModel` 可缺省或为 `null`，单项最大 128 个字符。
- `platform` 不由客户端提交，Worker 固定写入 `ios`。
- 不接受请求体之外的权限、账号或推送内容字段。

### 成功响应

新增和更新统一返回 HTTP 200：

```json
{
  "success": true,
  "data": {
    "deviceId": "11111111-2222-3333-4444-555555555555"
  }
}
```

### 错误响应

- JSON 或字段校验失败：HTTP 400。
- 已知路径使用非 POST 方法：HTTP 405，并返回 `Allow: POST`。
- 未知路径：HTTP 404。
- D1 执行失败：HTTP 500，仅返回通用错误，不暴露 SQL、绑定信息或 Cloudflare 内部异常。

所有响应使用 `application/json; charset=utf-8`。

## D1 数据模型

```sql
CREATE TABLE devices (
    device_id TEXT PRIMARY KEY,
    apns_token TEXT,
    apns_environment TEXT,
    platform TEXT NOT NULL DEFAULT 'ios',
    app_version TEXT,
    system_version TEXT,
    device_model TEXT,
    first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    token_updated_at TEXT,
    CHECK (apns_environment IS NULL OR apns_environment IN ('development', 'production'))
);
```

字段语义：

- `device_id`：由 iOS IDFV 生成并缓存到钥匙串的设备号，是记录唯一键。
- `apns_token`：Apple 返回的当前推送 Token，可为空且允许后续更新。
- `apns_environment`：Token 所属 APNs 环境。
- `platform`：客户端平台，本接口固定为 `ios`。
- `app_version`：App 对外版本号。
- `system_version`：iOS 系统版本。
- `device_model`：`iPhone` 或 `iPad` 等设备类型。
- `first_seen_at`：首次注册时间，后续更新保持不变。
- `last_seen_at`：最近一次成功注册或更新的时间。
- `token_updated_at`：最近一次提交非空 APNs Token 的时间。

## 写入规则

Worker 必须使用 D1 prepared statement 和 `.bind()`，禁止拼接客户端输入。写入使用 `device_id` 冲突更新：

- 首次无 Token 请求创建设备记录。
- 后续携带 Token 请求更新相同记录，不新增重复设备。
- 后续无 Token 请求保留已有 `apns_token`、`apns_environment` 和 `token_updated_at`。
- 新 Token 覆盖旧 Token，并刷新 `token_updated_at`。
- 每次成功请求更新版本、系统、设备类型和 `last_seen_at`。
- `first_seen_at` 永不因重复请求改变。

## 测试策略

使用 Cloudflare 官方 Workers Vitest 集成环境。测试在隔离的本地 D1 中先应用 `migrations/`，再通过 Worker 的真实 `fetch` 入口执行：

1. migration 创建字段和约束完整的 `devices` 表。
2. 首次无 Token 注册成功并写入一条设备记录。
3. 后续补充 APNs Token，记录数量仍为一。
4. Token 轮换后只保存最新 Token。
5. 后续无 Token 请求不会清除已有 Token 或 Token 更新时间。
6. 重复设备更新 `last_seen_at`，保留 `first_seen_at`。
7. 非法 UUID、非十六进制 Token、缺少或非法 APNs 环境返回 400 且不写库。
8. 未知路径返回 404；错误方法返回 405 和 `Allow: POST`。
9. D1 故障被转换为通用 500 响应，不泄露内部错误。

验证命令固定为：

```bash
cd worker
npm test
npm run typecheck
```

## 安全与发布边界

- App 不直接访问 D1，也不包含 Cloudflare API Token。
- 本阶段接口只在本地 Workers 测试环境运行，不执行 `wrangler deploy`。
- 本阶段不执行带 `--remote` 的 migration 或 D1 写入命令。
- 设备号和 APNs Token 不写入日志或测试快照。
- 在未来部署公开接口前，另行设计滥用防护和客户端可信性；固定密钥不能安全地作为 iOS App 身份凭据。
