// Every model the native library exposes. One line per model - the only place
// the shared bindings name a concrete model.
//
// This is the direction the dependencies have to run: the generic ABI must know
// the models, so `Bindings` depends on them, while a model only depends on the
// `ModelBinding` protocols in the core. That is also why the ABI takes a model id
// rather than exporting per-model symbols: one native library serves the whole
// SDK, and the host picks the model at runtime.

import DesertAnt
import Emo
import Redact
import Clear

let bindings: [String: any ModelBinding.Type] = [
    EmoBinding.id: EmoBinding.self,
    RedactBinding.id: RedactBinding.self,
    ClearBinding.id: ClearBinding.self,
]

/// The binding for a host-supplied model id, or nil if it is unknown.
func binding(for id: String) -> (any ModelBinding.Type)? { bindings[id] }
