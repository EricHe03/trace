#include "trace_curl_shim.h"
#include "trace_curl_vendor.h"
#include <curl/curlver.h>
#include <TargetConditionals.h>

int32_t trace_curl_runtime_available(void) {
    // Vendored source snapshot and runtime bridge are present in the integration.
    return 1;
}

int32_t trace_curl_runtime_supports_full_option_parity(void) {
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX || TARGET_OS_MACCATALYST
    // Simulator/macOS runtime uses host curl CLI parser/execution path.
    return 1;
#else
    // Device builds keep explicit fail-fast fallback until in-process tool/lib wiring is complete.
    return 0;
#endif
}

const char *trace_curl_runtime_backend_name(void) {
    return "CCurlShim(vendored)";
}

const char *trace_curl_runtime_supported_protocols_csv(void) {
    return "dict,file,ftp,ftps,gopher,gophers,http,https,imap,imaps,ipfs,ipns,ldap,ldaps,mqtt,pop3,pop3s,rtmp,rtmpe,rtmps,rtmpt,rtmpte,rtmpts,rtsp,scp,sftp,smb,smbs,smtp,smtps,telnet,tftp,ws,wss";
}

const char *trace_curl_runtime_version_string(void) {
    return LIBCURL_VERSION " (" TRACE_CURL_VENDOR_TAG " @ " TRACE_CURL_VENDOR_COMMIT ")";
}
