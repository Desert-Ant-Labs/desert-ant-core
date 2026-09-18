# speech.wav

Six seconds of `williamagain_01_crompton` from LibriVox, mono 16 kHz, taken
from 6 s in: "are in the public domain. For more information or to volunteer,
please visit librivox dot org". LibriVox recordings are in the public domain.

It is here, and exempted in `.gitignore`, because the browser and Node suites
assert a transcript and word timestamps. That needs speech that is identical on
every run, and downloading it would make both suites depend on a host other
than the Hub they already need.

The offset is deliberate. The first six seconds of the same recording are a
clip every quantized build of this model refuses, including the Core ML one
that ships on Apple: a window that produces nothing is a behaviour the model
has, and the pipeline retries it. A fixture that only the float16 web build
could transcribe was testing the weights, not the pipeline.
