# Faster first load on the M6 and A20 Pro

On the M6 and A20 Pro, the SDK compiles models for the Neural Engine with options that make the first load faster. On an iPhone 18 Pro, Voz loads in 9.5s with the options and 33.4s without them. Predictions and outputs are the same either way. The options go through a private Core ML API. To use only public APIs, set `DesertAnt.fasterNeuralEngineCompile = false` before the first model loads.
