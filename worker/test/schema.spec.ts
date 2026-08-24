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

  it.each([
    ["a missing token", "66666666-2222-3333-4444-555555555555", null],
    ["an empty token", "77777777-2222-3333-4444-555555555555", ""],
  ])("rejects development environment with %s", async (_, deviceId, apnsToken) => {
    await expect(
      env.DB
        .prepare(`
          INSERT INTO devices (device_id, apns_token, apns_environment)
          VALUES (?, ?, ?)
        `)
        .bind(deviceId, apnsToken, "development")
        .run()
    ).rejects.toThrow();
  });
});
