#ifndef TRACE_CURL_SHIM_H
#define TRACE_CURL_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t trace_curl_runtime_available(void);
int32_t trace_curl_runtime_supports_full_option_parity(void);
const char *trace_curl_runtime_backend_name(void);
const char *trace_curl_runtime_supported_protocols_csv(void);
const char *trace_curl_runtime_version_string(void);

#ifdef __cplusplus
}
#endif

#endif /* TRACE_CURL_SHIM_H */
