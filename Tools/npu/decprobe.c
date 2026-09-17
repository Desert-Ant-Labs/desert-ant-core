// Route the real int8 decoder through the classic TFLite interpreter with
// NNAPI enabled, and let logcat show the partition: how many ops the
// google-edgetpu NN driver claims, and whether it runs without the app-service
// allowlist refusal. dlopen's the LiteRt runtime we ship (it exports the
// classic TFLite C API) so this needs no extra libraries on device.
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>

typedef struct TfLiteModel TfLiteModel;
typedef struct TfLiteInterpreterOptions TfLiteInterpreterOptions;
typedef struct TfLiteInterpreter TfLiteInterpreter;

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "/data/local/tmp/decoder.tflite";
    void* h = dlopen("/data/local/tmp/libLiteRt.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }

    TfLiteModel* (*ModelCreateFromFile)(const char*) =
        dlsym(h, "TfLiteModelCreateFromFile");
    TfLiteInterpreterOptions* (*OptionsCreate)(void) =
        dlsym(h, "TfLiteInterpreterOptionsCreate");
    void (*OptionsSetUseNNAPI)(TfLiteInterpreterOptions*, int) =
        dlsym(h, "TfLiteInterpreterOptionsSetUseNNAPI");
    void (*OptionsSetNumThreads)(TfLiteInterpreterOptions*, int) =
        dlsym(h, "TfLiteInterpreterOptionsSetNumThreads");
    TfLiteInterpreter* (*InterpreterCreate)(const TfLiteModel*, const TfLiteInterpreterOptions*) =
        dlsym(h, "TfLiteInterpreterCreate");
    int (*AllocateTensors)(TfLiteInterpreter*) =
        dlsym(h, "TfLiteInterpreterAllocateTensors");
    int (*Invoke)(TfLiteInterpreter*) =
        dlsym(h, "TfLiteInterpreterInvoke");

    if (!ModelCreateFromFile || !OptionsSetUseNNAPI || !InterpreterCreate) {
        printf("missing symbols\n"); return 1;
    }
    TfLiteModel* model = ModelCreateFromFile(path);
    if (!model) { printf("model load failed: %s\n", path); return 1; }
    printf("model loaded: %s\n", path);

    TfLiteInterpreterOptions* opts = OptionsCreate();
    OptionsSetNumThreads(opts, 1);
    OptionsSetUseNNAPI(opts, 1);            // <- the NNAPI delegate, watch logcat

    TfLiteInterpreter* interp = InterpreterCreate(model, opts);
    if (!interp) { printf("interpreter create failed (NNAPI delegate refused?)\n"); return 1; }
    printf("interpreter created with NNAPI\n");

    int a = AllocateTensors(interp);
    printf("allocate_tensors status=%d\n", a);
    int r = Invoke(interp);
    printf("invoke status=%d\n", r);
    printf("RESULT: %s\n", r == 0 ? "decoder ran with NNAPI enabled" : "invoke failed");
    return 0;
}
