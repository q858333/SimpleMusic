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
