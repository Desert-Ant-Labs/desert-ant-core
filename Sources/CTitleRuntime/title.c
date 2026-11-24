#include "CTitleRuntime.h"

#ifdef __ANDROID__
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include <engine.h>

#define TITLE_API(X) \
    X(litert_lm_get_last_error_message) \
    X(litert_lm_engine_settings_create) \
    X(litert_lm_engine_settings_set_max_num_tokens) \
    X(litert_lm_engine_settings_delete) \
    X(litert_lm_engine_create) \
    X(litert_lm_engine_delete) \
    X(litert_lm_engine_tokenize) \
    X(litert_lm_tokenize_result_get_num_tokens) \
    X(litert_lm_tokenize_result_delete) \
    X(litert_lm_session_config_create) \
    X(litert_lm_session_config_set_apply_prompt_template) \
    X(litert_lm_session_config_set_max_output_tokens) \
    X(litert_lm_session_config_set_sampler_params) \
    X(litert_lm_session_config_delete) \
    X(litert_lm_sampler_params_create) \
    X(litert_lm_sampler_params_set_top_k) \
    X(litert_lm_sampler_params_set_top_p) \
    X(litert_lm_sampler_params_set_temperature) \
    X(litert_lm_sampler_params_delete) \
    X(litert_lm_engine_create_session) \
    X(litert_lm_session_delete) \
    X(litert_lm_input_data_create) \
    X(litert_lm_input_data_delete) \
    X(litert_lm_session_run_prefill) \
    X(litert_lm_session_run_decode) \
    X(litert_lm_responses_get_response_text_at) \
    X(litert_lm_responses_delete)

#define DECLARE(name) static __typeof__(&name) p_##name;
TITLE_API(DECLARE)
#undef DECLARE

static pthread_once_t load_once = PTHREAD_ONCE_INIT;
static char load_error[256];

static void load_runtime(void) {
    // Resolve the versioned C exports at runtime. Android cannot link against
    // these exports by name when the upstream library has no SONAME.
    void *library = dlopen("liblitert-lm.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        snprintf(load_error, sizeof(load_error), "%s", dlerror());
        return;
    }
#define LOAD(name) \
    p_##name = (__typeof__(&name))dlsym(library, #name); \
    if (!p_##name) { \
        snprintf(load_error, sizeof(load_error), "Missing LiteRT-LM export %s", #name); \
        dlclose(library); \
        return; \
    }
    TITLE_API(LOAD)
#undef LOAD
}

// The C API's error belongs to this thread and can be replaced by cleanup.
#define CHECK(name, ...) do { \
    LiteRtLmStatusCode status = p_litert_lm_##name(__VA_ARGS__); \
    if (status != 0) { \
        const char *message = p_litert_lm_get_last_error_message(); \
        snprintf(error, error_size, "%s (%d): %s", #name, (int)status, message ? message : ""); \
        goto cleanup; \
    } \
} while (0)

DalTitleEngine *dal_title_open(const char *path, int context_tokens, char *error, size_t error_size) {
    pthread_once(&load_once, load_runtime);
    if (load_error[0]) {
        snprintf(error, error_size, "%s", load_error);
        return NULL;
    }
    LiteRtLmEngineSettings *settings = NULL;
    DalTitleEngine *engine = NULL;
    CHECK(engine_settings_create, path, "cpu", NULL, NULL, &settings);
    CHECK(engine_settings_set_max_num_tokens, settings, context_tokens);
    CHECK(engine_create, settings, &engine);
cleanup:
    if (settings) p_litert_lm_engine_settings_delete(settings);
    return engine;
}

void dal_title_close(DalTitleEngine *engine) {
    p_litert_lm_engine_delete(engine);
}

int dal_title_token_count(DalTitleEngine *engine, const char *prompt, char *error, size_t error_size) {
    LiteRtLmTokenizeResult *result = NULL;
    size_t count = 0;
    int token_count = -1;
    CHECK(engine_tokenize, engine, prompt, &result);
    CHECK(tokenize_result_get_num_tokens, result, &count);
    if (count <= INT_MAX) {
        token_count = (int)count;
    } else {
        snprintf(error, error_size, "Prompt has too many tokens");
    }
cleanup:
    if (result) p_litert_lm_tokenize_result_delete(result);
    return token_count;
}

char *dal_title_generate(DalTitleEngine *engine, const char *prompt, size_t prompt_bytes,
                         int max_tokens, char *error, size_t error_size) {
    LiteRtLmSessionConfig *config = NULL;
    LiteRtLmSamplerParams *sampler = NULL;
    LiteRtLmSession *session = NULL;
    LiteRtLmInputData *input = NULL;
    LiteRtLmResponses *responses = NULL;
    const char *text = NULL;
    char *reply = NULL;

    CHECK(session_config_create, &config);
    CHECK(session_config_set_apply_prompt_template, config, false);
    CHECK(session_config_set_max_output_tokens, config, max_tokens);
    // LiteRT-LM 0.19.1's CPU executor implements greedy selection as TopP with k=1.
    CHECK(sampler_params_create, kLiteRtLmSamplerTypeTopP, &sampler);
    CHECK(sampler_params_set_top_k, sampler, 1);
    CHECK(sampler_params_set_top_p, sampler, 1.0f);
    CHECK(sampler_params_set_temperature, sampler, 1.0f);
    CHECK(session_config_set_sampler_params, config, sampler);
    CHECK(engine_create_session, engine, config, &session);
    CHECK(input_data_create, kLiteRtLmInputDataTypeText, prompt, prompt_bytes, &input);
    const LiteRtLmInputData *inputs[] = {input};
    CHECK(session_run_prefill, session, inputs, 1);
    CHECK(session_run_decode, session, &responses);
    CHECK(responses_get_response_text_at, responses, 0, &text);
    reply = strdup(text ? text : "");
    if (!reply) snprintf(error, error_size, "Allocating Title's reply failed");
cleanup:
    if (responses) p_litert_lm_responses_delete(responses);
    if (input) p_litert_lm_input_data_delete(input);
    if (session) p_litert_lm_session_delete(session);
    if (sampler) p_litert_lm_sampler_params_delete(sampler);
    if (config) p_litert_lm_session_config_delete(config);
    return reply;
}
#endif
