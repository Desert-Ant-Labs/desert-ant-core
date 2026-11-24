#ifndef C_TITLE_RUNTIME_H
#define C_TITLE_RUNTIME_H

#include <stddef.h>

typedef struct LiteRtLmEngine DalTitleEngine;

DalTitleEngine *dal_title_open(const char *path, int context_tokens, char *error, size_t error_size);
void dal_title_close(DalTitleEngine *engine);
int dal_title_token_count(DalTitleEngine *engine, const char *prompt, char *error, size_t error_size);
char *dal_title_generate(DalTitleEngine *engine, const char *prompt, size_t prompt_bytes,
                        int max_tokens, char *error, size_t error_size);

#endif
