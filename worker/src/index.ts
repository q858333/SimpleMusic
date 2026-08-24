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
