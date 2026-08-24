# Worker D1 设备注册验证报告

日期：2026-08-24

分支：`codex/worker-d1-device-registration`

Worker 实现提交：`483a016 feat: 添加Worker设备注册接口`

## 结论

`POST /api/v1/devices/register` 已通过本地 Workers pool 与本地 D1 集成验证。最终 Worker 全量测试为 25 passed、0 failed，TypeScript 类型检查退出码为 0。验证覆盖设备首次注册、APNs token 新增与轮换、重复注册不产生重复设备、时间戳与 metadata 更新、无 token 时保留既有 token，以及 400/404/405/500 HTTP 边界。

本报告只记录本地验证。没有 deploy，没有远程 migration 或远程 D1 写入，也没有修改 iOS/Xcode 工程。

## D1 与 migration 边界

- Wrangler 配置选择的 D1 database 名称：`disktone`。
- 本地测试使用的 migration：`worker/migrations/0001_create_devices.sql`。
- 测试通过官方 Workers Vitest pool 为 `Env.DB` 应用 migration，并使用隔离的本地 D1；没有使用 `--remote`。
- 报告不记录 database ID、Cloudflare account ID、访问 token 或其他凭据。

## RED 证据

### Schema

在创建 migration 前运行：

```bash
cd worker
npm test -- test/schema.spec.ts
```

`PRAGMA table_info(devices)` 返回空列集合，测试以“期望完整列、实际为空”失败。补充 APNs 约束测试在原约束下为 2 failed、2 passed，证明缺失或空 token 仍可错误携带 environment。

### Validation

在创建解析器生产文件前运行：

```bash
cd worker
npm test -- test/device-registration-validation.spec.ts
```

Vitest 以 `Cannot find module '../src/device-registration'` 失败，证明测试引用的是尚未实现的真实解析器接口。

### Endpoint 与持久化

在添加路由和 D1 upsert 前运行：

```bash
cd worker
npm test -- test/device-registration.spec.ts
```

结果为 10 failed、1 passed。首个失败为成功注册期望 HTTP 200、初始 Worker 实际返回 404；其余失败覆盖未写入 D1、400/405/500 边界尚不存在。未知路径 404 是初始 Worker 已具备的唯一通过项。

## 最终本地验证

### Task 3 focused

```bash
cd worker
npm test -- test/device-registration.spec.ts
```

- exit code：0
- Test Files：1 passed
- Tests：11 passed，0 failed

### 完整 Worker tests

```bash
cd worker
npm test
```

- exit code：0
- Test Files：3 passed
- Tests：25 passed，0 failed

### TypeScript 与 diff

```bash
cd worker
npm run typecheck

cd ..
git diff --check
```

- `tsc --noEmit` exit code：0
- `git diff --check` exit code：0，无输出
- 最终静态审计未发现 `wrangler deploy`、`--remote`、`console.log` 或 `console.error`

## 数据与错误安全边界

- D1 写入使用 `prepare(...).bind(...).run()`，未拼接设备号或 APNs token。
- `device_id` 唯一冲突走 upsert；`first_seen_at` 保持不变，`last_seen_at` 更新。
- 新 token 更新 token、environment 与 `token_updated_at`；缺失或 `null` token 保留既有 token、environment 与更新时间。空字符串 token 按输入契约返回 400，不写入或清除已有 token。
- D1 故障只返回通用 `internal_error`，响应不包含 SQL、表名或 D1 内部错误；生产代码没有记录 deviceId 或 APNs token 的日志。

## 明确 deferred

iOS 侧把设备注册信息上传到该 Worker 的接线、真机 APNs token 生命周期和端到端网络验证不在本 Worker 任务范围内，本次未实现或声称通过，状态为 DEFERRED。
