#ifndef CQUICHE_FFI_H
#define CQUICHE_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cquiche_mitm_session cquiche_mitm_session_t;

typedef enum cquiche_failure_reason {
    CQUICHE_FAILURE_NONE = 0,
    CQUICHE_FAILURE_ENGINE_UNAVAILABLE = 1,
    CQUICHE_FAILURE_SESSION_CREATE_FAILED = 2,
    CQUICHE_FAILURE_SESSION_NOT_READY = 3,
    CQUICHE_FAILURE_CERTIFICATE_PINNING = 4,
    CQUICHE_FAILURE_ECH_UNSUPPORTED = 5,
    CQUICHE_FAILURE_HANDSHAKE_FAILED = 6,
    CQUICHE_FAILURE_UNSUPPORTED_ALPN = 7,
    CQUICHE_FAILURE_TUNNEL_REQUIRED_UNAVAILABLE = 8,
    CQUICHE_FAILURE_PROTOCOL_ERROR = 9,
    CQUICHE_FAILURE_INTERNAL_ERROR = 10
} cquiche_failure_reason_t;

typedef enum cquiche_action_type {
    CQUICHE_ACTION_NONE = 0,
    CQUICHE_ACTION_DATAGRAM_TO_CLIENT = 1,
    CQUICHE_ACTION_DATAGRAM_TO_UPSTREAM = 2,
    CQUICHE_ACTION_HTTP3_REQUEST_HEADERS = 3,
    CQUICHE_ACTION_HTTP3_REQUEST_BODY = 4,
    CQUICHE_ACTION_HTTP3_REQUEST_END = 5,
    CQUICHE_ACTION_HTTP3_RESET_STREAM = 6,
    CQUICHE_ACTION_CONNECTION_CLOSED = 7,
    CQUICHE_ACTION_FALLBACK_REQUIRED = 8
} cquiche_action_type_t;

typedef struct cquiche_h3_event_info {
    uint64_t stream_id;
    size_t headers_len;
    size_t body_len;
} cquiche_h3_event_info_t;

typedef struct cquiche_mitm_open_config {
    const char *authority;
    uint16_t port;
    bool tunnel_policy_required;
    const uint8_t *downstream_leaf_cert_der;
    size_t downstream_leaf_cert_der_len;
    const uint8_t *downstream_private_key_der;
    size_t downstream_private_key_der_len;
} cquiche_mitm_open_config_t;

typedef struct cquiche_action_info {
    int32_t action_type;
    uint64_t stream_id;
    int32_t failure_reason;
    size_t payload_len;
    size_t metadata_len;
} cquiche_action_info_t;

typedef struct cquiche_mitm_stats {
    uint64_t datagrams_ingested_client;
    uint64_t datagrams_ingested_upstream;
    uint64_t datagrams_emitted_client;
    uint64_t datagrams_emitted_upstream;
    uint64_t h3_requests_seen;
    uint64_t h3_requests_completed;
    uint64_t fallback_events;
} cquiche_mitm_stats_t;

const char *cquiche_version_string(void);
bool cquiche_runtime_available(void);
int cquiche_http3_engine_state(void);

cquiche_mitm_session_t *cquiche_mitm_session_open_with_config(const cquiche_mitm_open_config_t *config);
cquiche_mitm_session_t *cquiche_mitm_session_open(const char *host, uint16_t port);
void cquiche_mitm_session_close(cquiche_mitm_session_t *session);
bool cquiche_mitm_session_ready(const cquiche_mitm_session_t *session);

int cquiche_mitm_session_ingest_datagram(
    cquiche_mitm_session_t *session,
    const uint8_t *payload,
    size_t payload_len,
    bool from_client
);

int cquiche_mitm_session_poll_action(
    cquiche_mitm_session_t *session,
    cquiche_action_info_t *action_info,
    uint8_t *payload_buffer,
    size_t payload_buffer_len,
    char *metadata_buffer,
    size_t metadata_buffer_len
);

int cquiche_mitm_session_submit_response(
    cquiche_mitm_session_t *session,
    uint64_t stream_id,
    uint16_t status_code,
    const char *headers_block,
    size_t headers_block_len,
    const uint8_t *body,
    size_t body_len,
    bool fin
);

int cquiche_mitm_session_tick(cquiche_mitm_session_t *session, uint64_t now_nanos);
int cquiche_mitm_session_last_failure_reason(const cquiche_mitm_session_t *session);
int cquiche_mitm_session_get_stats(
    const cquiche_mitm_session_t *session,
    cquiche_mitm_stats_t *stats
);

// Legacy adapter used by existing Swift call-sites.
int cquiche_mitm_session_poll_h3_event(
    cquiche_mitm_session_t *session,
    cquiche_h3_event_info_t *event_info,
    char *headers_buffer,
    size_t headers_buffer_len,
    uint8_t *body_buffer,
    size_t body_buffer_len
);

#ifdef __cplusplus
}
#endif

#endif
