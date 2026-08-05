export interface AudioHost {
  decode(path: string | null, bytes: Uint8Array | null, sampleRate: number): Promise<Float32Array>;
}

export function installAudioHost(): AudioHost;
export function decodeWav(bytes: Uint8Array): {
  samples: Float32Array;
  sampleRate: number;
  channels: number;
};
export function mixdownMono(interleaved: Float32Array, channels: number): Float32Array;
export function resampleLinear(samples: Float32Array, from: number, to: number): Float32Array;
