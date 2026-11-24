/// A session the factory built, with its model's license checks: one for this install when the
/// model loads, and one for each end-user device a run names.
struct LicensedSession: InferenceSession {
    let base: any InferenceSession
    let sdk: SDKInfo

    var runsConcurrently: Bool { base.runsConcurrently }

    func inputWidth(_ name: String) -> Int? { base.inputWidth(name) }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        licenseOnRun(sdk, deviceId: deviceId)
        return try await base.run(inputs: inputs, outputs: outputs, deviceId: deviceId)
    }
}
