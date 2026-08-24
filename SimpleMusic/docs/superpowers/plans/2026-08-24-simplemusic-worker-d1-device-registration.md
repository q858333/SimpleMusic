# SimpleMusic Worker D1 Device Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SimpleMusic 仓库中创建可本地运行和测试的 Cloudflare Worker，通过 D1 持久化设备号及后续到达的 APNs Token。

**Architecture:** `worker/` 是独立 TypeScript 子项目，原生 Worker 路由只暴露 `POST /api/v1/devices/register`，输入先由纯函数校验，再通过 D1 prepared statement upsert。Cloudflare Workers Vitest 测试环境为每项测试提供隔离的本地 D1，并在测试启动时应用真实 migration。

**Tech Stack:** Cloudflare Workers、D1、TypeScript 7.0.2、Wrangler 4.125.0、Vitest 4.1.11、`@cloudflare/vitest-pool-workers` 0.22.0、Node.js 24

**Spec:** `SimpleMusic/docs/superpowers/specs/2026-08-24-simplemusic-worker-d1-device-registration-design.md`

## Global Constraints

- Worker 子项目固定为仓库根目录下的 `worker/`，不得放进 iOS Xcode target。
- D1 binding 名称固定为 `DB`；远程数据库名称和 ID 必须来自 `wrangler d1 list --json`，禁止猜测。
- 若 Wrangler 未登录或列出多个无法唯一识别的 D1，停止并请用户选择，不执行建库、远程 migration 或部署。
- 本计划只运行本地 Workers/D1 测试，禁止 `wrangler deploy` 和任何带 `--remote` 的 D1 写入命令。
- App 不直接访问 D1；本计划不修改 iOS 自动上报代码。
- SQL 必须使用 `.prepare().bind()`；设备号和 APNs Token 不得写入日志或测试快照。
- `deviceId` 是唯一键；空 APNs Token 请求不得清除已有 Token。
- 有 Token 时 `apnsEnvironment` 只允许 `development` 或 `production`。
- 所有任务串行执行；只暂存本任务文件，保留现有 Xcode 工程和 entitlements 未提交改动。

---

### Task 1: Worker 测试骨架与 D1 migration

**Files:**
- Create: `worker/package.json`
- Create: `worker/package-lock.json`
- Create: `worker/tsconfig.json`
- Create: `worker/wrangler.jsonc`
- Create: `worker/vitest.config.ts`
- Create: `worker/src/index.ts`
- Create: `worker/test/env.d.ts`
- Create: `worker/test/apply-migrations.ts`
- Create: `worker/test/schema.spec.ts`
- Create: `worker/migrations/0001_create_devices.sql`

**Interfaces:**
- Consumes: 已登录 Wrangler 账户中的现有 SimpleMusic D1 数据库名称和 ID。
- Produces: `Cloudflare.Env.DB: D1Database`、`Cloudflare.Env.TEST_MIGRATIONS: D1Migration[]`，以及已应用 `0001_create_devices.sql` 的隔离本地测试数据库。

- [ ] **Step 1: 确认 Wrangler 登录和唯一 D1 绑定目标**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
env npm_config_cache=/tmp/simplemusic-worker-npm-cache npx --yes wrangler@4.125.0 whoami
env npm_config_cache=/tmp/simplemusic-worker-npm-cache npx --yes wrangler@4.125.0 d1 list --json
```

Expected: `whoami` 返回当前 Cloudflare 账户；D1 列表包含用户为 SimpleMusic 创建的数据库。记录该对象的真实 `name` 和 `uuid`。若登录失败或目标不唯一，停止并请求用户确认，不能继续写配置。

- [ ] **Step 2: 创建最小 TypeScript/Workers 配置**

Create `worker/package.json`:

```json
{
  "name": "simplemusic-worker",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "0.22.0",
    "@cloudflare/workers-types": "5.20260823.1",
    "@types/node": "26.2.0",
    "typescript": "7.0.2",
    "vitest": "4.1.11",
    "wrangler": "4.125.0"
  }
}
```

Create `worker/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "WebWorker"],
    "types": [
      "@cloudflare/workers-types",
      "@cloudflare/vitest-pool-workers",
      "node"
    ],
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts", "test/**/*.ts", "vitest.config.ts"]
}
```

Create `worker/wrangler.jsonc` with:

- `$schema` set to `node_modules/wrangler/config-schema.json`.
- `name` set to `simplemusic-device-service`.
- `main` set to `src/index.ts`.
- `compatibility_date` set to `2026-08-24`.
- One `d1_databases` entry whose `binding` is `DB`, whose `database_name` and `database_id` exactly match Step 1, and whose `migrations_dir` is `migrations`.

Install and lock dependencies:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
mkdir -p migrations src test
env npm_config_cache=/tmp/simplemusic-worker-npm-cache npm install
```

Expected: `package-lock.json` is created and `npm audit` does not block installation.

- [ ] **Step 3: 配置官方 Workers Vitest D1 migration 环境**

Create `worker/vitest.config.ts`:

```typescript
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const projectRoot = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig(async () => {
  const migrations = await readD1Migrations(
    path.join(projectRoot, "migrations")
  );

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { TEST_MIGRATIONS: migrations },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
```

Create `worker/test/env.d.ts`:

```typescript
declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
```

Create `worker/test/apply-migrations.ts`:

```typescript
import { applyD1Migrations, env } from "cloudflare:test";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
```

Create the initial `worker/src/index.ts` so the Workers test pool can load the configured main module before the registration route exists:

```typescript
interface Env {
  DB: D1Database;
}

export default {
  fetch(): Response {
    return Response.json(
      { success: false, error: { code: "not_found" } },
      { status: 404 }
    );
  },
} satisfies ExportedHandler<Env>;
```

- [ ] **Step 4: 写 migration 缺失时的失败测试**

Create `worker/test/schema.spec.ts` before creating the SQL migration:

```typescript
import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("devices migration", () => {
  it("creates the complete devices table", async () => {
    const { results } = await env.DB
      .prepare("PRAGMA table_info(devices)")
      .all<{ name: string; notnull: number; pk: number }>();

    expect(results.map((column) => column.name)).toEqual([
      "device_id",
      "apns_token",
      "apns_environment",
      "platform",
      "app_version",
      "system_version",
      "device_model",
      "first_seen_at",
      "last_seen_at",
      "token_updated_at",
    ]);
    expect(results.find((column) => column.name === "device_id")?.pk).toBe(1);
    expect(results.find((column) => column.name === "platform")?.notnull).toBe(1);
  });

  it("enforces the APNs environment constraint", async () => {
    await expect(
      env.DB
        .prepare(`
          INSERT INTO devices (device_id, apns_environment)
          VALUES (?, ?)
        `)
        .bind("11111111-2222-3333-4444-555555555555", "invalid")
        .run()
    ).rejects.toThrow();
  });
});
```

- [ ] **Step 5: 运行测试确认 RED**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/schema.spec.ts
```

Expected: FAIL because `PRAGMA table_info(devices)` returns no columns.

- [ ] **Step 6: 添加最小 migration**

Create `worker/migrations/0001_create_devices.sql`:

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
    CHECK (
        apns_environment IS NULL
        OR apns_environment IN ('development', 'production')
    )
);
```

- [ ] **Step 7: 运行 schema 测试和类型检查确认 GREEN**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/schema.spec.ts
npm run typecheck
```

Expected: schema test PASS; typecheck exit 0.

- [ ] **Step 8: 提交 Task 1**

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
git add worker/package.json worker/package-lock.json worker/tsconfig.json worker/wrangler.jsonc worker/vitest.config.ts worker/src/index.ts worker/test/env.d.ts worker/test/apply-migrations.ts worker/test/schema.spec.ts worker/migrations/0001_create_devices.sql
git diff --cached --check
git commit -m "feat: 初始化Worker与D1迁移"
```

---

### Task 2: 设备注册输入模型与校验

**Files:**
- Create: `worker/src/device-registration.ts`
- Create: `worker/test/device-registration-validation.spec.ts`

**Interfaces:**
- Consumes: 原始 `unknown` JSON 请求体。
- Produces: `parseDeviceRegistration(value: unknown): DeviceRegistrationPayload`；失败抛出 `DeviceRegistrationValidationError`，成功返回规范化的小写设备号和 APNs Token。

- [ ] **Step 1: 写输入校验失败测试**

Create `worker/test/device-registration-validation.spec.ts`:

```typescript
import { describe, expect, it } from "vitest";
import {
  DeviceRegistrationValidationError,
  parseDeviceRegistration,
} from "../src/device-registration";

const deviceId = "11111111-2222-3333-4444-555555555555";

describe("parseDeviceRegistration", () => {
  it("accepts registration before the APNs token arrives", () => {
    expect(parseDeviceRegistration({ deviceId })).toEqual({
      deviceId,
      apnsToken: null,
      apnsEnvironment: null,
      appVersion: null,
      systemVersion: null,
      deviceModel: null,
    });
  });

  it("normalizes a later APNs token registration", () => {
    expect(
      parseDeviceRegistration({
        deviceId: deviceId.toUpperCase(),
        apnsToken: "01A2ff",
        apnsEnvironment: "development",
        appVersion: "1.0.0",
        systemVersion: "18.0",
        deviceModel: "iPhone",
      })
    ).toEqual({
      deviceId,
      apnsToken: "01a2ff",
      apnsEnvironment: "development",
      appVersion: "1.0.0",
      systemVersion: "18.0",
      deviceModel: "iPhone",
    });
  });

  it.each([
    [{}, "deviceId"],
    [{ deviceId: "not-a-uuid" }, "deviceId"],
    [{ deviceId, apnsToken: "not-hex", apnsEnvironment: "development" }, "apnsToken"],
    [{ deviceId, apnsToken: "a".repeat(513), apnsEnvironment: "development" }, "apnsToken"],
    [{ deviceId, apnsToken: "01a2" }, "apnsEnvironment"],
    [{ deviceId, apnsToken: "01a2", apnsEnvironment: "invalid" }, "apnsEnvironment"],
    [{ deviceId, apnsEnvironment: "production" }, "apnsEnvironment"],
    [{ deviceId, appVersion: "x".repeat(129) }, "appVersion"],
  ])("rejects invalid payload %j", (payload, field) => {
    expect(() => parseDeviceRegistration(payload)).toThrow(
      DeviceRegistrationValidationError
    );
    try {
      parseDeviceRegistration(payload);
    } catch (error) {
      expect((error as DeviceRegistrationValidationError).field).toBe(field);
    }
  });
});
```

- [ ] **Step 2: 运行测试确认 RED**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/device-registration-validation.spec.ts
```

Expected: FAIL because `src/device-registration.ts` does not exist.

- [ ] **Step 3: 实现最小输入解析器**

Create `worker/src/device-registration.ts`:

```typescript
export type APNsEnvironment = "development" | "production";

export interface DeviceRegistrationPayload {
  deviceId: string;
  apnsToken: string | null;
  apnsEnvironment: APNsEnvironment | null;
  appVersion: string | null;
  systemVersion: string | null;
  deviceModel: string | null;
}

export class DeviceRegistrationValidationError extends Error {
  constructor(
    readonly field: string,
    message: string
  ) {
    super(message);
    this.name = "DeviceRegistrationValidationError";
  }
}

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const hexPattern = /^[0-9a-f]+$/i;

function optionalString(
  value: unknown,
  field: string,
  maximumLength: number
): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length === 0 || value.length > maximumLength) {
    throw new DeviceRegistrationValidationError(field, `Invalid ${field}`);
  }
  return value;
}

export function parseDeviceRegistration(value: unknown): DeviceRegistrationPayload {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new DeviceRegistrationValidationError("body", "Invalid JSON body");
  }

  const body = value as Record<string, unknown>;
  if (typeof body.deviceId !== "string" || !uuidPattern.test(body.deviceId)) {
    throw new DeviceRegistrationValidationError("deviceId", "Invalid deviceId");
  }

  const apnsToken = optionalString(body.apnsToken, "apnsToken", 512);
  const rawEnvironment = body.apnsEnvironment;
  let apnsEnvironment: APNsEnvironment | null = null;

  if (apnsToken !== null) {
    if (!hexPattern.test(apnsToken)) {
      throw new DeviceRegistrationValidationError("apnsToken", "Invalid apnsToken");
    }
    if (rawEnvironment !== "development" && rawEnvironment !== "production") {
      throw new DeviceRegistrationValidationError("apnsEnvironment", "Invalid apnsEnvironment");
    }
    apnsEnvironment = rawEnvironment;
  } else if (rawEnvironment !== undefined && rawEnvironment !== null) {
    throw new DeviceRegistrationValidationError("apnsEnvironment", "Token is required");
  }

  return {
    deviceId: body.deviceId.toLowerCase(),
    apnsToken: apnsToken?.toLowerCase() ?? null,
    apnsEnvironment,
    appVersion: optionalString(body.appVersion, "appVersion", 128),
    systemVersion: optionalString(body.systemVersion, "systemVersion", 128),
    deviceModel: optionalString(body.deviceModel, "deviceModel", 128),
  };
}
```

- [ ] **Step 4: 运行 Task 2 测试和类型检查确认 GREEN**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/device-registration-validation.spec.ts
npm run typecheck
```

Expected: all validation tests PASS; typecheck exit 0.

- [ ] **Step 5: 提交 Task 2**

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
git add worker/src/device-registration.ts worker/test/device-registration-validation.spec.ts
git diff --cached --check
git commit -m "feat: 添加设备注册参数校验"
```

---

### Task 3: Worker 路由与 D1 upsert

**Files:**
- Modify: `worker/src/device-registration.ts`
- Modify: `worker/src/index.ts`
- Create: `worker/test/device-registration.spec.ts`

**Interfaces:**
- Consumes: `POST /api/v1/devices/register` JSON body and `Env.DB`.
- Produces: default `ExportedHandler<Env>` Worker；成功 `{ success: true, data: { deviceId } }`，校验失败 400，未知路径 404，错误方法 405，D1 故障 500。

- [ ] **Step 1: 写真实 Worker/D1 行为测试**

Create `worker/test/device-registration.spec.ts` with these helpers and cases:

```typescript
import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const deviceId = "11111111-2222-3333-4444-555555555555";
const endpoint = "https://simplemusic.test/api/v1/devices/register";

interface DeviceRow {
  device_id: string;
  apns_token: string | null;
  apns_environment: string | null;
  platform: string;
  app_version: string | null;
  system_version: string | null;
  device_model: string | null;
  first_seen_at: string;
  last_seen_at: string;
  token_updated_at: string | null;
}

async function register(payload: unknown): Promise<Response> {
  return SELF.fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

async function loadDevice(): Promise<DeviceRow | null> {
  return env.DB
    .prepare("SELECT * FROM devices WHERE device_id = ?")
    .bind(deviceId)
    .first<DeviceRow>();
}

describe("POST /api/v1/devices/register", () => {
  it("registers a device before the APNs token arrives", async () => {
    const response = await register({
      deviceId,
      appVersion: "1.0.0",
      systemVersion: "18.0",
      deviceModel: "iPhone",
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe(
      "application/json; charset=utf-8"
    );
    expect(await response.json()).toEqual({
      success: true,
      data: { deviceId },
    });
    expect(await loadDevice()).toMatchObject({
      device_id: deviceId,
      apns_token: null,
      apns_environment: null,
      platform: "ios",
      app_version: "1.0.0",
      system_version: "18.0",
      device_model: "iPhone",
      token_updated_at: null,
    });
  });

  it("adds and rotates the APNs token without duplicating the device", async () => {
    await register({ deviceId });
    await register({
      deviceId,
      apnsToken: "01a2ff",
      apnsEnvironment: "development",
    });
    await register({
      deviceId,
      apnsToken: "02b3aa",
      apnsEnvironment: "production",
    });

    const count = await env.DB
      .prepare("SELECT COUNT(*) AS count FROM devices WHERE device_id = ?")
      .bind(deviceId)
      .first<{ count: number }>();
    expect(count?.count).toBe(1);
    expect(await loadDevice()).toMatchObject({
      apns_token: "02b3aa",
      apns_environment: "production",
    });
    expect((await loadDevice())?.token_updated_at).not.toBeNull();
  });

  it("does not erase an existing token when a later request has no token", async () => {
    await register({
      deviceId,
      apnsToken: "01a2ff",
      apnsEnvironment: "development",
    });
    await env.DB
      .prepare("UPDATE devices SET token_updated_at = '2000-01-01 00:00:00' WHERE device_id = ?")
      .bind(deviceId)
      .run();

    await register({ deviceId, appVersion: "1.0.1" });

    expect(await loadDevice()).toMatchObject({
      apns_token: "01a2ff",
      apns_environment: "development",
      token_updated_at: "2000-01-01 00:00:00",
      app_version: "1.0.1",
    });
  });

  it("keeps first_seen_at and refreshes last_seen_at", async () => {
    await register({ deviceId });
    await env.DB
      .prepare("UPDATE devices SET first_seen_at = '1999-01-01 00:00:00', last_seen_at = '2000-01-01 00:00:00' WHERE device_id = ?")
      .bind(deviceId)
      .run();

    await register({ deviceId });

    const row = await loadDevice();
    expect(row?.first_seen_at).toBe("1999-01-01 00:00:00");
    expect(row?.last_seen_at).not.toBe("2000-01-01 00:00:00");
  });

  it("returns 400 without writing invalid input", async () => {
    const response = await register({ deviceId: "invalid" });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      success: false,
      error: { code: "invalid_request", field: "deviceId" },
    });
    const count = await env.DB
      .prepare("SELECT COUNT(*) AS count FROM devices")
      .first<{ count: number }>();
    expect(count?.count).toBe(0);
  });

  it("returns 400 for malformed JSON", async () => {
    const response = await SELF.fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not-json",
    });
    expect(response.status).toBe(400);
  });

  it("returns 405 for another method", async () => {
    const response = await SELF.fetch(endpoint, { method: "GET" });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
  });

  it("returns 404 for another path", async () => {
    const response = await SELF.fetch("https://simplemusic.test/unknown");
    expect(response.status).toBe(404);
  });

  it("returns a generic 500 response when D1 fails", async () => {
    await env.DB.exec("DROP TABLE devices");
    const response = await register({ deviceId });
    const body = JSON.stringify(await response.json());

    expect(response.status).toBe(500);
    expect(body).toContain("internal_error");
    expect(body).not.toContain("devices");
    expect(body).not.toContain("SQLITE");
  });
});
```

- [ ] **Step 2: 运行集成测试确认 RED**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/device-registration.spec.ts
```

Expected: FAIL because the initial Worker only returns 404 and the persistence handler does not exist.

- [ ] **Step 3: 添加 D1 upsert 函数**

Append to `worker/src/device-registration.ts`:

```typescript
export async function saveDeviceRegistration(
  db: D1Database,
  payload: DeviceRegistrationPayload
): Promise<void> {
  await db
    .prepare(`
      INSERT INTO devices (
        device_id,
        apns_token,
        apns_environment,
        platform,
        app_version,
        system_version,
        device_model,
        first_seen_at,
        last_seen_at,
        token_updated_at
      )
      VALUES (
        ?, ?, ?, 'ios', ?, ?, ?,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        CASE WHEN ? IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END
      )
      ON CONFLICT(device_id) DO UPDATE SET
        apns_token = CASE
          WHEN excluded.apns_token IS NULL THEN devices.apns_token
          ELSE excluded.apns_token
        END,
        apns_environment = CASE
          WHEN excluded.apns_token IS NULL THEN devices.apns_environment
          ELSE excluded.apns_environment
        END,
        app_version = excluded.app_version,
        system_version = excluded.system_version,
        device_model = excluded.device_model,
        last_seen_at = CURRENT_TIMESTAMP,
        token_updated_at = CASE
          WHEN excluded.apns_token IS NULL THEN devices.token_updated_at
          ELSE CURRENT_TIMESTAMP
        END
    `)
    .bind(
      payload.deviceId,
      payload.apnsToken,
      payload.apnsEnvironment,
      payload.appVersion,
      payload.systemVersion,
      payload.deviceModel,
      payload.apnsToken
    )
    .run();
}
```

- [ ] **Step 4: 添加 Worker 路由和 JSON 错误边界**

Replace the initial implementation in `worker/src/index.ts` with:

```typescript
import {
  DeviceRegistrationValidationError,
  parseDeviceRegistration,
  saveDeviceRegistration,
} from "./device-registration";

const registrationPath = "/api/v1/devices/register";

interface Env {
  DB: D1Database;
}

function json(body: unknown, status: number, headers?: HeadersInit): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("content-type", "application/json; charset=utf-8");
  return Response.json(body, {
    status,
    headers: responseHeaders,
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== registrationPath) {
      return json({ success: false, error: { code: "not_found" } }, 404);
    }
    if (request.method !== "POST") {
      return json(
        { success: false, error: { code: "method_not_allowed" } },
        405,
        { Allow: "POST" }
      );
    }

    let rawBody: unknown;
    try {
      rawBody = await request.json();
    } catch {
      return json(
        { success: false, error: { code: "invalid_request", field: "body" } },
        400
      );
    }

    try {
      const payload = parseDeviceRegistration(rawBody);
      await saveDeviceRegistration(env.DB, payload);
      return json(
        { success: true, data: { deviceId: payload.deviceId } },
        200
      );
    } catch (error) {
      if (error instanceof DeviceRegistrationValidationError) {
        return json(
          {
            success: false,
            error: { code: "invalid_request", field: error.field },
          },
          400
        );
      }
      return json(
        { success: false, error: { code: "internal_error" } },
        500
      );
    }
  },
} satisfies ExportedHandler<Env>;
```

- [ ] **Step 5: 运行 Task 3 集成测试确认 GREEN**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test -- test/device-registration.spec.ts
npm run typecheck
```

Expected: all route, persistence, token lifecycle, validation, timestamp and D1 failure tests PASS; typecheck exit 0.

- [ ] **Step 6: 运行完整 Worker 验证**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic/worker
npm test
npm run typecheck
```

Expected: schema、validation、integration 全部 PASS，0 failed；typecheck exit 0。确认日志没有打印设备号、APNs Token、SQL 或 D1 内部错误。

- [ ] **Step 7: 审计远程操作边界和工作树**

Run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
git diff --check
git status --short
rg -n "wrangler deploy|--remote|console\\.(log|error)|apnsToken" worker
```

Expected:

- `git diff --check` 无输出。
- `worker/` 没有部署脚本和带 `--remote` 的写入命令。
- `apnsToken` 只出现在输入、校验、SQL binding 和断言字段中，不出现在日志调用。
- 现有 Xcode 工程、entitlements 和用户状态改动仍保持未暂存。

- [ ] **Step 8: 提交 Task 3**

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
git add worker/src/device-registration.ts worker/src/index.ts worker/test/device-registration.spec.ts
git diff --cached --check
git commit -m "feat: 添加Worker设备注册接口"
```

- [ ] **Step 9: 写实施报告并提交**

Create `SimpleMusic/docs/testing/2026-08-24-worker-d1-device-registration-verification.md` containing:

- selected D1 database name only，不记录 database ID、账户 ID 或 Token；
- migration filename and local-only boundary;
- RED evidence for schema、validation and endpoint;
- final `npm test` passed/failed counts;
- final `npm run typecheck` exit status;
- explicit statement that no deploy、remote migration、remote D1 write or iOS code change occurred.

Then run:

```bash
cd /Users/db/Documents/git/my/music/SimpleMusic
git add SimpleMusic/docs/testing/2026-08-24-worker-d1-device-registration-verification.md
git diff --cached --check
git commit -m "test: 记录Worker设备注册验证结果"
git status --short
```

Expected: verification document is committed alone; remaining status contains only the user's pre-existing Xcode project, entitlements, or UI state changes.
