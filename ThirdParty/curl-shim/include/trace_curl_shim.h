#ifndef TRACE_CURL_SHIM_H
#define TRACE_CURL_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct trace_curl_execute_result {
    int32_t exit_code;
    char *stdout_utf8;
    char *stderr_utf8;
} trace_curl_execute_result;

typedef struct trace_curl_parse_result {
    int32_t parameter_error;
    int32_t transfer_count;
    int32_t url_count;
    char *stderr_utf8;
} trace_curl_parse_result;

int32_t trace_curl_runtime_available(void);
int32_t trace_curl_runtime_supports_full_option_parity(void);
const char *trace_curl_runtime_backend_name(void);
const char *trace_curl_runtime_supported_protocols_csv(void);
const char *trace_curl_runtime_version_string(void);

int32_t trace_curl_execute_argv(
    int32_t argc,
    const char *const *argv,
    trace_curl_execute_result *result
);
void trace_curl_execute_result_dispose(trace_curl_execute_result *result);

int32_t trace_curl_parse_argv(
    int32_t argc,
    const char *const *argv,
    trace_curl_parse_result *result
);
void trace_curl_parse_result_dispose(trace_curl_parse_result *result);

const char *trace_curl_runtime_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* TRACE_CURL_SHIM_H */
