// This target exists to carry `Resources/PrivacyInfo.xcprivacy`, the usage
// turnstile's App Store privacy manifest, and nothing imports it. SwiftPM will
// not build a target without a source file, hence this one.
//
// The manifest is not a resource of `Usage` itself because a resource makes
// SwiftPM generate a `Bundle.module` accessor that imports Foundation, and
// `Usage` keeps Foundation off Android and WASI. Package.swift gives `Usage` an
// Apple-only edge to this target instead.
