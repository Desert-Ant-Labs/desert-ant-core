// The one import a model SDK needs.
//
// The core is built as small single-purpose modules (Regex, JSON, ModelStore,
// Inference, …) so each has one job, one test suite, and its own per-platform
// backends. That granularity is right for the core and wrong for its consumers:
// an SDK had to name six of them across as many files, and adding a capability
// meant editing every SDK's manifest as well.
//
// `DesertAnt` re-exports the common public surface, so an SDK writes one import.
// Optional capabilities such as AudioIO and AudioDSP stay separate and are
// dependencies only of models that use them.

// Text + data primitives.
@_exported import Regex
@_exported import JSON
@_exported import TextNormalization

// Environment, HTTP, and the usage turnstile.
@_exported import PlatformSupport
@_exported import Usage

// Models: the catalog's declarations, the verified store behind them (models
// are downloaded on demand, never bundled as package resources), and the
// platform's inference sessions.
@_exported import ModelCatalog
@_exported import ModelStore
@_exported import Inference

// Cross-language bindings: the length-prefixed FFI buffer and the Android JNI
// harness (empty off the platforms that use it). What a model implements to be
// reachable from another language comes with ModelCatalog.
@_exported import FFIBuffer
@_exported import HostBridge
