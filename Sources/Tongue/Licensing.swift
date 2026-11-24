import DesertAnt

func licenseLoad() {
    licenseOnLoad(TongueModel.sdkInfo)
}

func licenseRun() {
    licenseOnRun(TongueModel.sdkInfo, deviceId: InferenceContext.deviceId)
}
