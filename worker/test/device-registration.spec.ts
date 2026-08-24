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
    await env.DB
      .prepare("UPDATE devices SET token_updated_at = '2000-01-01 00:00:00' WHERE device_id = ?")
      .bind(deviceId)
      .run();
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
    expect((await loadDevice())?.token_updated_at).not.toBe(
      "2000-01-01 00:00:00"
    );
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

  it("does not erase an existing token when a later request has a null token", async () => {
    await register({
      deviceId,
      apnsToken: "01a2ff",
      apnsEnvironment: "development",
    });
    await env.DB
      .prepare("UPDATE devices SET token_updated_at = '2000-01-01 00:00:00' WHERE device_id = ?")
      .bind(deviceId)
      .run();

    const response = await register({ deviceId, apnsToken: null });

    expect(response.status).toBe(200);
    expect(await loadDevice()).toMatchObject({
      apns_token: "01a2ff",
      apns_environment: "development",
      token_updated_at: "2000-01-01 00:00:00",
    });
  });

  it("rejects an empty token without erasing the existing token", async () => {
    await register({
      deviceId,
      apnsToken: "01a2ff",
      apnsEnvironment: "development",
    });

    const response = await register({
      deviceId,
      apnsToken: "",
      apnsEnvironment: "production",
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      success: false,
      error: { code: "invalid_request", field: "apnsToken" },
    });
    expect(await loadDevice()).toMatchObject({
      apns_token: "01a2ff",
      apns_environment: "development",
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
      .prepare("SELECT COUNT(*) AS count FROM devices WHERE device_id = ?")
      .bind("invalid")
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
    expect(await response.json()).toEqual({
      success: false,
      error: { code: "invalid_request", field: "body" },
    });
  });

  it("returns 405 for another method", async () => {
    const response = await SELF.fetch(endpoint, { method: "GET" });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
    expect(await response.json()).toEqual({
      success: false,
      error: { code: "method_not_allowed" },
    });
  });

  it("returns 404 for another path", async () => {
    const response = await SELF.fetch("https://simplemusic.test/unknown");
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      success: false,
      error: { code: "not_found" },
    });
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
