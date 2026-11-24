import Testing
@testable import Usage

struct DeviceInstallTests {
    private let secret = "0123456789abcdef0123456789abcdef"

    @Test func aSecretGivesTheHMACOfTheAppAndTheDeviceId() {
        #expect(deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret)
            == "683119e6-c29e-877f-bb29-17ea7359b2e2")
        #expect(deviceInstallId(deviceId: "dispositivo-ñ-7", app: "server:acme-api", secret: secret)
            == "18ad7c00-9138-8878-a365-2bb739f64c41")
    }

    @Test func noSecretGivesThePlainHash() {
        #expect(deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: nil)
            == "d7af4132-3cfb-8f76-a183-bd33d318ebd0")
    }

    @Test func theSameInputsGiveTheSameId() {
        let first = deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret)
        #expect(first == deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret))
    }

    @Test func anotherDeviceAppOrSecretGivesAnotherId() {
        let base = deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret)
        #expect(base != deviceInstallId(deviceId: "device-8", app: "server:acme-api", secret: secret))
        #expect(base != deviceInstallId(deviceId: "device-7", app: "server:other-api", secret: secret))
        #expect(base != deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret + "x"))
    }

    @Test func theAppCountsWithoutCaseAndOuterWhitespace() {
        let base = deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret)
        #expect(base == deviceInstallId(deviceId: "device-7", app: "server:Acme-API", secret: secret))
        #expect(base == deviceInstallId(deviceId: "device-7", app: " server:acme-api\n", secret: secret))
        #expect(base != deviceInstallId(deviceId: "Device-7", app: "server:acme-api", secret: secret))
    }

    @Test func withoutASecretTwoAPIKeysGiveTwoIds() {
        let first = deviceInstallId(deviceId: "user-1", app: "server:node", secret: nil, apiKey: "dal_one")
        #expect(first != deviceInstallId(deviceId: "user-1", app: "server:node", secret: nil, apiKey: "dal_two"))
        #expect(first == deviceInstallId(deviceId: "user-1", app: "server:node", secret: nil, apiKey: "dal_one"))
        #expect(deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: nil, apiKey: nil)
            == "d7af4132-3cfb-8f76-a183-bd33d318ebd0")
    }

    @Test func withASecretTheAPIKeyChangesNothing() {
        #expect(deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret, apiKey: "dal_one")
            == deviceInstallId(deviceId: "device-7", app: "server:acme-api", secret: secret))
    }

    @Test func partsDoNotRunTogether() {
        #expect(deviceInstallId(deviceId: "b", app: "server:a", secret: secret)
            != deviceInstallId(deviceId: "ab", app: "server:", secret: secret))
    }
}
