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
