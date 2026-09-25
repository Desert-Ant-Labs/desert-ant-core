// Decisive NNAPI probe for the Tensor TPU: enumerate NN devices, then try to
// compile a trivial 1-op model *for the google-edgetpu device specifically*.
// The point is the allowlist question - does the NN HAL refuse a normal caller
// the way vendor.google.edgetpu_app_service did, or is this door open?
//
// Pure NDK NNAPI C API against the platform libneuralnetworks.so; no LiteRT.
#include <android/NeuralNetworks.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

int main(void) {
    uint32_t n = 0;
    if (ANeuralNetworks_getDeviceCount(&n) != ANEURALNETWORKS_NO_ERROR) {
        printf("getDeviceCount failed\n");
        return 1;
    }
    printf("NNAPI devices: %u\n", n);

    ANeuralNetworksDevice* edgetpu = NULL;
    for (uint32_t i = 0; i < n; i++) {
        ANeuralNetworksDevice* dev = NULL;
        if (ANeuralNetworks_getDevice(i, &dev) != ANEURALNETWORKS_NO_ERROR) continue;
        const char* name = NULL;
        int64_t feature = 0;
        int32_t type = -1;
        ANeuralNetworksDevice_getName(dev, &name);
        ANeuralNetworksDevice_getFeatureLevel(dev, &feature);
        ANeuralNetworksDevice_getType(dev, &type);
        printf("  [%u] %-28s type=%d featureLevel=%lld\n",
               i, name ? name : "?", type, (long long)feature);
        if (name && strstr(name, "edgetpu")) edgetpu = dev;
    }
    if (!edgetpu) {
        printf("no edgetpu NNAPI device visible to this process\n");
        return 0;
    }

    // Smallest possible model: out = in0 + in1, one ADD op, float32 scalars.
    ANeuralNetworksModel* model = NULL;
    ANeuralNetworksModel_create(&model);
    ANeuralNetworksOperandType f32 = {
        .type = ANEURALNETWORKS_TENSOR_FLOAT32, .dimensionCount = 1,
        .dimensions = (uint32_t[]){1}, .scale = 0.0f, .zeroPoint = 0};
    ANeuralNetworksOperandType act = {
        .type = ANEURALNETWORKS_INT32, .dimensionCount = 0,
        .dimensions = NULL, .scale = 0.0f, .zeroPoint = 0};
    for (int i = 0; i < 3; i++) ANeuralNetworksModel_addOperand(model, &f32); // 0,1,2
    ANeuralNetworksModel_addOperand(model, &act);                            // 3
    int32_t fuse = ANEURALNETWORKS_FUSED_NONE;
    ANeuralNetworksModel_setOperandValue(model, 3, &fuse, sizeof(fuse));
    uint32_t ins[3] = {0, 1, 3};
    uint32_t outs[1] = {2};
    ANeuralNetworksModel_addOperation(model, ANEURALNETWORKS_ADD, 3, ins, 1, outs);
    uint32_t mi[2] = {0, 1};
    uint32_t mo[1] = {2};
    ANeuralNetworksModel_identifyInputsAndOutputs(model, 2, mi, 1, mo);
    if (ANeuralNetworksModel_finish(model) != ANEURALNETWORKS_NO_ERROR) {
        printf("model_finish failed\n");
        return 1;
    }

    // Does the driver claim it can run this op?
    bool supported[1] = {false};
    ANeuralNetworksModel_getSupportedOperationsForDevices(
        model, (const ANeuralNetworksDevice*[]){edgetpu}, 1, supported);
    printf("edgetpu supports ADD: %s\n", supported[0] ? "yes" : "no");

    // The real test: compile FOR the edgetpu device. This is where the
    // app-service allowlist refused the LiteRT/SB path (error 16).
    ANeuralNetworksCompilation* comp = NULL;
    int status = ANeuralNetworksCompilation_createForDevices(
        model, (const ANeuralNetworksDevice*[]){edgetpu}, 1, &comp);
    printf("createForDevices status=%d\n", status);
    if (status != ANEURALNETWORKS_NO_ERROR) {
        printf("RESULT: NN HAL refused compilation (same gate)\n");
        return 0;
    }
    status = ANeuralNetworksCompilation_finish(comp);
    printf("compilation_finish status=%d\n", status);
    printf("RESULT: %s\n", status == ANEURALNETWORKS_NO_ERROR
           ? "TPU COMPILE SUCCEEDED via NNAPI - the door is open"
           : "compile started but finish failed");
    return 0;
}
