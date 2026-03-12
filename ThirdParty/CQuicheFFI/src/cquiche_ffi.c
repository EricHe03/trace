#include "cquiche_ffi.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#if defined(CQUICHE_WITH_QUICHE)
#include "quiche.h"
#endif

typedef struct cquiche_action_node {
    cquiche_action_info_t info;
    uint8_t *payload;
    size_t payload_len;
    char *metadata;
    size_t metadata_len;
    struct cquiche_action_node *next;
} cquiche_action_node_t;

#if defined(CQUICHE_WITH_QUICHE)
typedef struct cquiche_header_encode_context {
    char *buffer;
    size_t length;
    size_t capacity;
    bool failed;
} cquiche_header_encode_context_t;

typedef struct cquiche_owned_header_list {
    quiche_h3_header *headers;
    uint8_t **name_storage;
    uint8_t **value_storage;
    size_t count;
} cquiche_owned_header_list_t;
#endif

struct cquiche_mitm_session {
    char *authority;
    uint16_t port;
    bool ready;
    bool tunnel_policy_required;
    int32_t last_failure_reason;
    char last_failure_detail[160];
    uint64_t next_stream_id;
    cquiche_action_node_t *action_head;
    cquiche_action_node_t *action_tail;
    cquiche_mitm_stats_t stats;

#if defined(CQUICHE_WITH_QUICHE)
    quiche_config *downstream_config;
    quiche_h3_config *downstream_h3_config;
    quiche_conn *downstream_conn;
    quiche_h3_conn *downstream_h3_conn;
    bool close_action_emitted;
    bool authority_retry_emitted;

    struct sockaddr_storage local_addr;
    socklen_t local_addr_len;
    struct sockaddr_storage peer_addr;
    socklen_t peer_addr_len;

    uint8_t ingest_buffer[65535];
    uint8_t egress_buffer[1500];

    char *cert_pem_path;
    char *key_pem_path;
#endif
};

static const int32_t CQUICHE_SUCCESS = 0;
static const int32_t CQUICHE_POLL_NO_ACTION = 0;
static const int32_t CQUICHE_POLL_HAS_ACTION = 1;
static const int32_t CQUICHE_ERROR_INVALID_ARGUMENT = -1;
static const int32_t CQUICHE_ERROR_SESSION_NOT_READY = -2;
static const int32_t CQUICHE_ERROR_INTERNAL = -3;

#if defined(CQUICHE_WITH_QUICHE)
static const size_t CQUICHE_LOCAL_CONN_ID_LEN = 16;
static const size_t CQUICHE_MAX_TOKEN_LEN = (sizeof("trace-quiche") - 1) + QUICHE_MAX_CONN_ID_LEN;
static const char CQUICHE_TOKEN_PREFIX[] = "trace-quiche";
#endif

static char *duplicate_string(const char *value)
{
    if (value == NULL)
    {
        return NULL;
    }

    const size_t length = strlen(value);
    char *out = (char *)malloc(length + 1);
    if (out == NULL)
    {
        return NULL;
    }

    memcpy(out, value, length);
    out[length] = '\0';
    return out;
}

static uint8_t *duplicate_bytes(const uint8_t *value, size_t length)
{
    if (value == NULL || length == 0)
    {
        return NULL;
    }

    uint8_t *out = (uint8_t *)malloc(length);
    if (out == NULL)
    {
        return NULL;
    }

    memcpy(out, value, length);
    return out;
}

static char *duplicate_chars(const char *value, size_t length)
{
    if (value == NULL || length == 0)
    {
        return NULL;
    }

    char *out = (char *)malloc(length + 1);
    if (out == NULL)
    {
        return NULL;
    }

    memcpy(out, value, length);
    out[length] = '\0';
    return out;
}

static void free_action_node(cquiche_action_node_t *node)
{
    if (node == NULL)
    {
        return;
    }

    free(node->payload);
    free(node->metadata);
    free(node);
}

static void clear_action_queue(cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return;
    }

    cquiche_action_node_t *node = session->action_head;
    while (node != NULL)
    {
        cquiche_action_node_t *next = node->next;
        free_action_node(node);
        node = next;
    }

    session->action_head = NULL;
    session->action_tail = NULL;
}

static int enqueue_action(
    cquiche_mitm_session_t *session,
    int32_t action_type,
    uint64_t stream_id,
    int32_t failure_reason,
    const uint8_t *payload,
    size_t payload_len,
    const char *metadata,
    size_t metadata_len)
{
    if (session == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    cquiche_action_node_t *node = (cquiche_action_node_t *)calloc(1, sizeof(cquiche_action_node_t));
    if (node == NULL)
    {
        return CQUICHE_ERROR_INTERNAL;
    }

    node->payload = duplicate_bytes(payload, payload_len);
    if (payload_len > 0 && node->payload == NULL)
    {
        free_action_node(node);
        return CQUICHE_ERROR_INTERNAL;
    }

    node->metadata = duplicate_chars(metadata, metadata_len);
    if (metadata_len > 0 && node->metadata == NULL)
    {
        free_action_node(node);
        return CQUICHE_ERROR_INTERNAL;
    }

    node->payload_len = payload_len;
    node->metadata_len = metadata_len;
    node->info.action_type = action_type;
    node->info.stream_id = stream_id;
    node->info.failure_reason = failure_reason;
    node->info.payload_len = payload_len;
    node->info.metadata_len = metadata_len;

    if (session->action_tail != NULL)
    {
        session->action_tail->next = node;
    }
    else
    {
        session->action_head = node;
    }

    session->action_tail = node;
    return CQUICHE_SUCCESS;
}

static cquiche_action_node_t *dequeue_action(cquiche_mitm_session_t *session)
{
    if (session == NULL || session->action_head == NULL)
    {
        return NULL;
    }

    cquiche_action_node_t *node = session->action_head;
    session->action_head = node->next;
    if (session->action_head == NULL)
    {
        session->action_tail = NULL;
    }

    node->next = NULL;
    return node;
}

static const char *failure_reason_key(int32_t reason)
{
    switch (reason)
    {
    case CQUICHE_FAILURE_ENGINE_UNAVAILABLE:
        return "engineUnavailable";
    case CQUICHE_FAILURE_SESSION_CREATE_FAILED:
        return "sessionCreateFailed";
    case CQUICHE_FAILURE_SESSION_NOT_READY:
        return "sessionNotReady";
    case CQUICHE_FAILURE_CERTIFICATE_PINNING:
        return "certificatePinning";
    case CQUICHE_FAILURE_ECH_UNSUPPORTED:
        return "echUnsupported";
    case CQUICHE_FAILURE_HANDSHAKE_FAILED:
        return "handshakeFailed";
    case CQUICHE_FAILURE_UNSUPPORTED_ALPN:
        return "unsupportedALPN";
    case CQUICHE_FAILURE_TUNNEL_REQUIRED_UNAVAILABLE:
        return "tunnelRequiredUnavailable";
    case CQUICHE_FAILURE_PROTOCOL_ERROR:
        return "protocolError";
    case CQUICHE_FAILURE_INTERNAL_ERROR:
    default:
        return "internalError";
    }
}

static void clear_last_failure_detail(cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return;
    }

    session->last_failure_detail[0] = '\0';
}

static void set_last_failure_detail(cquiche_mitm_session_t *session, const char *detail)
{
    if (session == NULL)
    {
        return;
    }

    if (detail == NULL || detail[0] == '\0')
    {
        clear_last_failure_detail(session);
        return;
    }

    int written = snprintf(
        session->last_failure_detail,
        sizeof(session->last_failure_detail),
        "%s",
        detail
    );
    if (written < 0)
    {
        clear_last_failure_detail(session);
    }
}

static const char *tls_alert_detail_name(uint64_t alert_code)
{
    switch (alert_code)
    {
    case 42:
        return "bad_certificate";
    case 46:
        return "certificate_unknown";
    case 48:
        return "unknown_ca";
    default:
        return "other";
    }
}

static int emit_fallback(cquiche_mitm_session_t *session, int32_t reason)
{
    if (session == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    clear_last_failure_detail(session);
    session->last_failure_reason = reason;
    session->stats.fallback_events += 1;
    session->ready = false;

    const char *reason_key = failure_reason_key(reason);
    return enqueue_action(
        session,
        CQUICHE_ACTION_FALLBACK_REQUIRED,
        0,
        reason,
        NULL,
        0,
        reason_key,
        strlen(reason_key)
    );
}

#if defined(CQUICHE_WITH_QUICHE)
static bool equals_case_insensitive_len(
    const char *lhs,
    size_t lhs_len,
    const char *rhs,
    size_t rhs_len)
{
    if (lhs == NULL || rhs == NULL || lhs_len != rhs_len)
    {
        return false;
    }

    return strncasecmp(lhs, rhs, lhs_len) == 0;
}

static bool emit_retry_with_authority(cquiche_mitm_session_t *session)
{
    if (session == NULL || session->downstream_conn == NULL || session->authority_retry_emitted)
    {
        return false;
    }

    const uint8_t *server_name = NULL;
    size_t server_name_len = 0;
    quiche_conn_server_name(session->downstream_conn, &server_name, &server_name_len);

    if (server_name == NULL || server_name_len == 0)
    {
        return false;
    }

    const char *server_name_chars = (const char *)server_name;
    if (session->authority != NULL)
    {
        const size_t authority_len = strlen(session->authority);
        if (equals_case_insensitive_len(session->authority, authority_len, server_name_chars, server_name_len))
        {
            return false;
        }
    }

    const int enqueue_result = enqueue_action(
        session,
        CQUICHE_ACTION_RETRY_WITH_AUTHORITY,
        0,
        CQUICHE_FAILURE_HANDSHAKE_FAILED,
        NULL,
        0,
        server_name_chars,
        server_name_len
    );
    if (enqueue_result != CQUICHE_SUCCESS)
    {
        return false;
    }

    session->authority_retry_emitted = true;
    session->stats.fallback_events += 1;
    return true;
}

static void update_close_failure_reason(cquiche_mitm_session_t *session)
{
    if (session == NULL || session->downstream_conn == NULL || session->last_failure_reason != CQUICHE_FAILURE_NONE)
    {
        return;
    }

    clear_last_failure_detail(session);

    bool is_app = false;
    uint64_t error_code = 0;
    const uint8_t *reason = NULL;
    size_t reason_len = 0;
    (void)reason;
    (void)reason_len;

    if (quiche_conn_peer_error(session->downstream_conn, &is_app, &error_code, &reason, &reason_len))
    {
        if (!is_app)
        {
            const uint64_t tls_alert_base = 0x100;
            const uint64_t tls_alert_bad_certificate = tls_alert_base + 42;
            const uint64_t tls_alert_certificate_unknown = tls_alert_base + 46;
            const uint64_t tls_alert_unknown_ca = tls_alert_base + 48;

            if (error_code == tls_alert_bad_certificate ||
                error_code == tls_alert_certificate_unknown ||
                error_code == tls_alert_unknown_ca)
            {
                session->last_failure_reason = CQUICHE_FAILURE_CERTIFICATE_PINNING;
                uint64_t alert_code = error_code - tls_alert_base;
                char detail[160];
                int written = snprintf(
                    detail,
                    sizeof(detail),
                    "peer_tls_alert=%s,alert=%llu,raw=%llu",
                    tls_alert_detail_name(alert_code),
                    (unsigned long long)alert_code,
                    (unsigned long long)error_code
                );
                if (written >= 0)
                {
                    set_last_failure_detail(session, detail);
                }
                else
                {
                    clear_last_failure_detail(session);
                }
                return;
            }
        }

        session->last_failure_reason = CQUICHE_FAILURE_HANDSHAKE_FAILED;
        char detail[160];
        int written = snprintf(
            detail,
            sizeof(detail),
            "peer_error=is_app_%u,code=%llu",
            is_app ? 1U : 0U,
            (unsigned long long)error_code
        );
        if (written >= 0)
        {
            set_last_failure_detail(session, detail);
        }
        else
        {
            clear_last_failure_detail(session);
        }
        return;
    }

    if (quiche_conn_local_error(session->downstream_conn, &is_app, &error_code, &reason, &reason_len))
    {
        session->last_failure_reason = CQUICHE_FAILURE_HANDSHAKE_FAILED;
        char detail[160];
        int written = snprintf(
            detail,
            sizeof(detail),
            "local_error=is_app_%u,code=%llu",
            is_app ? 1U : 0U,
            (unsigned long long)error_code
        );
        if (written >= 0)
        {
            set_last_failure_detail(session, detail);
        }
        else
        {
            clear_last_failure_detail(session);
        }
        return;
    }

    if (!quiche_conn_is_established(session->downstream_conn))
    {
        session->last_failure_reason = CQUICHE_FAILURE_HANDSHAKE_FAILED;
        set_last_failure_detail(session, "state=closed_before_established");
    }
}

static void close_and_unlink_path(char **path)
{
    if (path == NULL || *path == NULL)
    {
        return;
    }

    unlink(*path);
    free(*path);
    *path = NULL;
}

static bool append_to_header_buffer(
    cquiche_header_encode_context_t *ctx,
    const uint8_t *data,
    size_t data_len)
{
    if (ctx == NULL || ctx->failed)
    {
        return false;
    }

    if (data_len == 0)
    {
        return true;
    }

    if (ctx->length + data_len + 1 > ctx->capacity)
    {
        size_t next_capacity = ctx->capacity == 0 ? 1024 : ctx->capacity;
        while (next_capacity < ctx->length + data_len + 1)
        {
            next_capacity *= 2;
        }

        char *next_buffer = (char *)realloc(ctx->buffer, next_capacity);
        if (next_buffer == NULL)
        {
            ctx->failed = true;
            return false;
        }

        ctx->buffer = next_buffer;
        ctx->capacity = next_capacity;
    }

    memcpy(ctx->buffer + ctx->length, data, data_len);
    ctx->length += data_len;
    ctx->buffer[ctx->length] = '\0';
    return true;
}

static int h3_header_serialize_callback(
    uint8_t *name,
    size_t name_len,
    uint8_t *value,
    size_t value_len,
    void *argp)
{
    cquiche_header_encode_context_t *ctx = (cquiche_header_encode_context_t *)argp;
    if (ctx == NULL)
    {
        return -1;
    }

    if (!append_to_header_buffer(ctx, name, name_len))
    {
        return -1;
    }

    static const uint8_t separator = '\t';
    if (!append_to_header_buffer(ctx, &separator, 1))
    {
        return -1;
    }

    if (!append_to_header_buffer(ctx, value, value_len))
    {
        return -1;
    }

    static const uint8_t newline = '\n';
    if (!append_to_header_buffer(ctx, &newline, 1))
    {
        return -1;
    }

    return 0;
}

static bool is_h3_alpn(const uint8_t *alpn, size_t alpn_len)
{
    if (alpn == NULL || alpn_len == 0)
    {
        return false;
    }

    if (alpn_len >= 2 && alpn[0] == 'h' && alpn[1] == '3')
    {
        return true;
    }

    return false;
}

static char *base64_encode_with_line_breaks(
    const uint8_t *input,
    size_t input_len,
    size_t *output_len)
{
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    if (input == NULL || input_len == 0)
    {
        return NULL;
    }

    const size_t encoded_len = ((input_len + 2) / 3) * 4;
    const size_t line_breaks = encoded_len == 0 ? 0 : ((encoded_len - 1) / 64);
    const size_t capacity = encoded_len + line_breaks + 1;

    char *encoded = (char *)malloc(capacity);
    if (encoded == NULL)
    {
        return NULL;
    }

    size_t in_index = 0;
    size_t out_index = 0;
    size_t line_count = 0;

    while (in_index < input_len)
    {
        const size_t remaining = input_len - in_index;
        const uint32_t octet_a = input[in_index++];
        const uint32_t octet_b = remaining > 1 ? input[in_index++] : 0;
        const uint32_t octet_c = remaining > 2 ? input[in_index++] : 0;

        const uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

        encoded[out_index++] = table[(triple >> 18) & 0x3F];
        encoded[out_index++] = table[(triple >> 12) & 0x3F];
        encoded[out_index++] = remaining > 1 ? table[(triple >> 6) & 0x3F] : '=';
        encoded[out_index++] = remaining > 2 ? table[triple & 0x3F] : '=';

        line_count += 4;
        if (line_count == 64 && out_index < capacity - 1)
        {
            encoded[out_index++] = '\n';
            line_count = 0;
        }
    }

    encoded[out_index] = '\0';
    if (output_len != NULL)
    {
        *output_len = out_index;
    }

    return encoded;
}

static char *build_pem_block(
    const char *label,
    const uint8_t *der,
    size_t der_len,
    size_t *pem_len)
{
    if (label == NULL || der == NULL || der_len == 0)
    {
        return NULL;
    }

    size_t encoded_len = 0;
    char *encoded = base64_encode_with_line_breaks(der, der_len, &encoded_len);
    if (encoded == NULL)
    {
        return NULL;
    }

    const size_t header_len = strlen("-----BEGIN ") + strlen(label) + strlen("-----\n");
    const size_t footer_len = strlen("\n-----END ") + strlen(label) + strlen("-----\n");
    const size_t total_len = header_len + encoded_len + footer_len;

    char *pem = (char *)malloc(total_len + 1);
    if (pem == NULL)
    {
        free(encoded);
        return NULL;
    }

    int written = snprintf(
        pem,
        total_len + 1,
        "-----BEGIN %s-----\n%s\n-----END %s-----\n",
        label,
        encoded,
        label
    );
    free(encoded);

    if (written <= 0)
    {
        free(pem);
        return NULL;
    }

    if (pem_len != NULL)
    {
        *pem_len = (size_t)written;
    }

    return pem;
}

static char *write_temp_file(
    const char *prefix,
    const uint8_t *contents,
    size_t contents_len)
{
    if (prefix == NULL || contents == NULL || contents_len == 0)
    {
        return NULL;
    }

    const char *tmp_root = getenv("TMPDIR");
    if (tmp_root == NULL || tmp_root[0] == '\0')
    {
        tmp_root = "/tmp";
    }

    const size_t tmp_root_len = strlen(tmp_root);
    const bool needs_separator = tmp_root_len > 0 ? tmp_root[tmp_root_len - 1] != '/' : true;

    char path_template[PATH_MAX];
    const int path_len = snprintf(
        path_template,
        sizeof(path_template),
        "%s%s%sXXXXXX",
        tmp_root,
        needs_separator ? "/" : "",
        prefix
    );
    if (path_len <= 0 || (size_t)path_len >= sizeof(path_template))
    {
        return NULL;
    }

    int fd = mkstemp(path_template);
    if (fd < 0)
    {
        return NULL;
    }

    size_t total_written = 0;
    while (total_written < contents_len)
    {
        const ssize_t wrote = write(fd, contents + total_written, contents_len - total_written);
        if (wrote <= 0)
        {
            close(fd);
            unlink(path_template);
            return NULL;
        }

        total_written += (size_t)wrote;
    }

    if (close(fd) != 0)
    {
        unlink(path_template);
        return NULL;
    }

    return duplicate_string(path_template);
}

static bool write_temp_pem_file(
    char **path_slot,
    const char *prefix,
    const char *pem,
    size_t pem_len)
{
    if (path_slot == NULL || prefix == NULL || pem == NULL || pem_len == 0)
    {
        return false;
    }

    char *path = write_temp_file(prefix, (const uint8_t *)pem, pem_len);
    if (path == NULL)
    {
        return false;
    }

    if (*path_slot != NULL)
    {
        unlink(*path_slot);
        free(*path_slot);
    }

    *path_slot = path;
    return true;
}

static bool configure_socket_addresses(cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return false;
    }

    memset(&session->local_addr, 0, sizeof(session->local_addr));
    memset(&session->peer_addr, 0, sizeof(session->peer_addr));

    struct sockaddr_in *local = (struct sockaddr_in *)&session->local_addr;
    local->sin_family = AF_INET;
    local->sin_port = htons(session->port == 0 ? 443 : session->port);
    local->sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    struct sockaddr_in *peer = (struct sockaddr_in *)&session->peer_addr;
    peer->sin_family = AF_INET;
    peer->sin_port = htons(49152);
    peer->sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    session->local_addr_len = sizeof(struct sockaddr_in);
    session->peer_addr_len = sizeof(struct sockaddr_in);
    return true;
}

static void free_owned_headers(cquiche_owned_header_list_t *list)
{
    if (list == NULL)
    {
        return;
    }

    if (list->name_storage != NULL)
    {
        for (size_t i = 0; i < list->count; i++)
        {
            free(list->name_storage[i]);
        }
    }

    if (list->value_storage != NULL)
    {
        for (size_t i = 0; i < list->count; i++)
        {
            free(list->value_storage[i]);
        }
    }

    free(list->headers);
    free(list->name_storage);
    free(list->value_storage);

    list->headers = NULL;
    list->name_storage = NULL;
    list->value_storage = NULL;
    list->count = 0;
}

static bool append_owned_header(
    cquiche_owned_header_list_t *list,
    const char *name,
    size_t name_len,
    const char *value,
    size_t value_len)
{
    if (list == NULL || name == NULL || value == NULL || name_len == 0)
    {
        return false;
    }

    const size_t next_count = list->count + 1;

    quiche_h3_header *next_headers = (quiche_h3_header *)realloc(list->headers, next_count * sizeof(quiche_h3_header));
    if (next_headers == NULL)
    {
        return false;
    }
    list->headers = next_headers;

    uint8_t **next_names = (uint8_t **)realloc(list->name_storage, next_count * sizeof(uint8_t *));
    if (next_names == NULL)
    {
        return false;
    }
    list->name_storage = next_names;

    uint8_t **next_values = (uint8_t **)realloc(list->value_storage, next_count * sizeof(uint8_t *));
    if (next_values == NULL)
    {
        return false;
    }
    list->value_storage = next_values;

    uint8_t *name_storage = (uint8_t *)malloc(name_len);
    uint8_t *value_storage = (uint8_t *)malloc(value_len == 0 ? 1 : value_len);
    if (name_storage == NULL || value_storage == NULL)
    {
        free(name_storage);
        free(value_storage);
        return false;
    }

    memcpy(name_storage, name, name_len);
    if (value_len > 0)
    {
        memcpy(value_storage, value, value_len);
    }

    list->name_storage[list->count] = name_storage;
    list->value_storage[list->count] = value_storage;

    list->headers[list->count].name = name_storage;
    list->headers[list->count].name_len = name_len;
    list->headers[list->count].value = value_storage;
    list->headers[list->count].value_len = value_len;

    list->count = next_count;
    return true;
}

static cquiche_owned_header_list_t parse_response_header_block(
    const char *headers_block,
    size_t headers_block_len,
    uint16_t status_code)
{
    cquiche_owned_header_list_t list;
    memset(&list, 0, sizeof(list));

    bool has_status_header = false;

    if (headers_block != NULL && headers_block_len > 0)
    {
        size_t line_start = 0;
        while (line_start < headers_block_len)
        {
            size_t line_end = line_start;
            while (line_end < headers_block_len && headers_block[line_end] != '\n')
            {
                line_end += 1;
            }

            if (line_end > line_start)
            {
                const char *line = headers_block + line_start;
                const size_t line_len = line_end - line_start;

                const char *tab = memchr(line, '\t', line_len);
                if (tab != NULL && tab > line)
                {
                    size_t name_len = (size_t)(tab - line);
                    size_t value_len = line_len - name_len - 1;
                    const char *name = line;
                    const char *value = tab + 1;

                    if (value_len > 0 && value[value_len - 1] == '\r')
                    {
                        value_len -= 1;
                    }

                    if (name_len == strlen(":status") && memcmp(name, ":status", strlen(":status")) == 0)
                    {
                        has_status_header = true;
                    }

                    if (!append_owned_header(&list, name, name_len, value, value_len))
                    {
                        free_owned_headers(&list);
                        memset(&list, 0, sizeof(list));
                        return list;
                    }
                }
            }

            line_start = line_end + 1;
        }
    }

    if (!has_status_header)
    {
        char status_text[8];
        const int written = snprintf(status_text, sizeof(status_text), "%u", status_code);
        if (written <= 0)
        {
            free_owned_headers(&list);
            memset(&list, 0, sizeof(list));
            return list;
        }

        if (!append_owned_header(
                &list,
                ":status",
                strlen(":status"),
                status_text,
                (size_t)written))
        {
            free_owned_headers(&list);
            memset(&list, 0, sizeof(list));
            return list;
        }
    }

    return list;
}

static int drain_downstream_egress(cquiche_mitm_session_t *session)
{
    if (session == NULL || session->downstream_conn == NULL)
    {
        return CQUICHE_SUCCESS;
    }

    quiche_send_info send_info;
    memset(&send_info, 0, sizeof(send_info));

    while (true)
    {
        ssize_t written = quiche_conn_send(
            session->downstream_conn,
            session->egress_buffer,
            sizeof(session->egress_buffer),
            &send_info
        );

        if (written == QUICHE_ERR_DONE)
        {
            break;
        }

        if (written < 0)
        {
            return emit_fallback(session, CQUICHE_FAILURE_HANDSHAKE_FAILED);
        }

        if (enqueue_action(
                session,
                CQUICHE_ACTION_DATAGRAM_TO_CLIENT,
                0,
                CQUICHE_FAILURE_NONE,
                session->egress_buffer,
                (size_t)written,
                NULL,
                0) != CQUICHE_SUCCESS)
        {
            return emit_fallback(session, CQUICHE_FAILURE_INTERNAL_ERROR);
        }

        session->stats.datagrams_emitted_client += 1;
    }

    if (quiche_conn_is_closed(session->downstream_conn) && !session->close_action_emitted)
    {
        update_close_failure_reason(session);
        session->close_action_emitted = true;
        enqueue_action(
            session,
            CQUICHE_ACTION_CONNECTION_CLOSED,
            0,
            session->last_failure_reason,
            NULL,
            0,
            NULL,
            0
        );
    }

    return CQUICHE_SUCCESS;
}

static int pump_h3_events(cquiche_mitm_session_t *session)
{
    if (session == NULL || session->downstream_conn == NULL || session->downstream_h3_conn == NULL)
    {
        return CQUICHE_SUCCESS;
    }

    while (true)
    {
        quiche_h3_event *event = NULL;
        int64_t stream_or_error = quiche_h3_conn_poll(
            session->downstream_h3_conn,
            session->downstream_conn,
            &event
        );

        if (stream_or_error == QUICHE_H3_ERR_DONE)
        {
            return CQUICHE_SUCCESS;
        }

        if (stream_or_error < 0)
        {
            if (event != NULL)
            {
                quiche_h3_event_free(event);
            }

            return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
        }

        const uint64_t stream_id = (uint64_t)stream_or_error;
        enum quiche_h3_event_type type = quiche_h3_event_type(event);

        switch (type)
        {
        case QUICHE_H3_EVENT_HEADERS:
        {
            cquiche_header_encode_context_t header_context;
            memset(&header_context, 0, sizeof(header_context));

            int iterate_result = quiche_h3_event_for_each_header(
                event,
                h3_header_serialize_callback,
                &header_context
            );

            if (iterate_result != 0 || header_context.failed)
            {
                free(header_context.buffer);
                quiche_h3_event_free(event);
                return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
            }

            const int enqueue_result = enqueue_action(
                session,
                CQUICHE_ACTION_HTTP3_REQUEST_HEADERS,
                stream_id,
                CQUICHE_FAILURE_NONE,
                NULL,
                0,
                header_context.buffer,
                header_context.length
            );
            free(header_context.buffer);

            if (enqueue_result != CQUICHE_SUCCESS)
            {
                quiche_h3_event_free(event);
                return emit_fallback(session, CQUICHE_FAILURE_INTERNAL_ERROR);
            }

            session->stats.h3_requests_seen += 1;
            break;
        }
        case QUICHE_H3_EVENT_DATA:
        {
            while (true)
            {
                ssize_t body_read = quiche_h3_recv_body(
                    session->downstream_h3_conn,
                    session->downstream_conn,
                    stream_id,
                    session->ingest_buffer,
                    sizeof(session->ingest_buffer)
                );

                if (body_read == QUICHE_H3_ERR_DONE)
                {
                    break;
                }

                if (body_read < 0)
                {
                    quiche_h3_event_free(event);
                    return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
                }

                if (body_read == 0)
                {
                    break;
                }

                if (enqueue_action(
                        session,
                        CQUICHE_ACTION_HTTP3_REQUEST_BODY,
                        stream_id,
                        CQUICHE_FAILURE_NONE,
                        session->ingest_buffer,
                        (size_t)body_read,
                        NULL,
                        0) != CQUICHE_SUCCESS)
                {
                    quiche_h3_event_free(event);
                    return emit_fallback(session, CQUICHE_FAILURE_INTERNAL_ERROR);
                }
            }

            break;
        }
        case QUICHE_H3_EVENT_FINISHED:
            if (enqueue_action(
                    session,
                    CQUICHE_ACTION_HTTP3_REQUEST_END,
                    stream_id,
                    CQUICHE_FAILURE_NONE,
                    NULL,
                    0,
                    NULL,
                    0) != CQUICHE_SUCCESS)
            {
                quiche_h3_event_free(event);
                return emit_fallback(session, CQUICHE_FAILURE_INTERNAL_ERROR);
            }
            break;
        case QUICHE_H3_EVENT_RESET:
            enqueue_action(
                session,
                CQUICHE_ACTION_HTTP3_RESET_STREAM,
                stream_id,
                CQUICHE_FAILURE_NONE,
                NULL,
                0,
                NULL,
                0
            );
            break;
        case QUICHE_H3_EVENT_GOAWAY:
        case QUICHE_H3_EVENT_PRIORITY_UPDATE:
            break;
        }

        quiche_h3_event_free(event);
    }
}

static void mint_token(
    const uint8_t *dcid,
    size_t dcid_len,
    uint8_t *token,
    size_t *token_len)
{
    const size_t prefix_len = sizeof(CQUICHE_TOKEN_PREFIX) - 1;
    memcpy(token, CQUICHE_TOKEN_PREFIX, prefix_len);
    memcpy(token + prefix_len, dcid, dcid_len);
    *token_len = prefix_len + dcid_len;
}

static bool validate_token(
    const uint8_t *token,
    size_t token_len,
    uint8_t *odcid,
    size_t *odcid_len)
{
    const size_t prefix_len = sizeof(CQUICHE_TOKEN_PREFIX) - 1;

    if (token == NULL || token_len <= prefix_len)
    {
        return false;
    }

    if (memcmp(token, CQUICHE_TOKEN_PREFIX, prefix_len) != 0)
    {
        return false;
    }

    const size_t extracted_len = token_len - prefix_len;
    if (*odcid_len < extracted_len)
    {
        return false;
    }

    memcpy(odcid, token + prefix_len, extracted_len);
    *odcid_len = extracted_len;
    return true;
}

static bool initialize_downstream_runtime(
    cquiche_mitm_session_t *session,
    const cquiche_mitm_open_config_t *config)
{
    if (session == NULL || config == NULL)
    {
        return false;
    }

    session->downstream_config = quiche_config_new(QUICHE_PROTOCOL_VERSION);
    if (session->downstream_config == NULL)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_CREATE_FAILED;
        return false;
    }

    quiche_config_set_application_protos(
        session->downstream_config,
        (uint8_t *)QUICHE_H3_APPLICATION_PROTOCOL,
        sizeof(QUICHE_H3_APPLICATION_PROTOCOL) - 1
    );

    quiche_config_set_max_idle_timeout(session->downstream_config, 30000);
    quiche_config_set_max_recv_udp_payload_size(session->downstream_config, sizeof(session->egress_buffer));
    quiche_config_set_max_send_udp_payload_size(session->downstream_config, sizeof(session->egress_buffer));
    quiche_config_set_initial_max_data(session->downstream_config, 10 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_bidi_local(session->downstream_config, 1 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_bidi_remote(session->downstream_config, 1 * 1024 * 1024);
    quiche_config_set_initial_max_stream_data_uni(session->downstream_config, 1 * 1024 * 1024);
    quiche_config_set_initial_max_streams_bidi(session->downstream_config, 100);
    quiche_config_set_initial_max_streams_uni(session->downstream_config, 100);
    quiche_config_set_disable_active_migration(session->downstream_config, true);
    quiche_config_set_cc_algorithm(session->downstream_config, QUICHE_CC_RENO);

    if (config->downstream_leaf_cert_der == NULL ||
        config->downstream_leaf_cert_der_len == 0 ||
        config->downstream_private_key_der == NULL ||
        config->downstream_private_key_der_len == 0)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_CREATE_FAILED;
        return false;
    }

    size_t cert_pem_len = 0;
    char *cert_pem = build_pem_block(
        "CERTIFICATE",
        config->downstream_leaf_cert_der,
        config->downstream_leaf_cert_der_len,
        &cert_pem_len
    );
    if (cert_pem == NULL)
    {
        session->last_failure_reason = CQUICHE_FAILURE_INTERNAL_ERROR;
        return false;
    }

    size_t key_pem_len = 0;
    char *key_pem = build_pem_block(
        "RSA PRIVATE KEY",
        config->downstream_private_key_der,
        config->downstream_private_key_der_len,
        &key_pem_len
    );
    if (key_pem == NULL)
    {
        free(cert_pem);
        session->last_failure_reason = CQUICHE_FAILURE_INTERNAL_ERROR;
        return false;
    }

    bool wrote_cert = write_temp_pem_file(&session->cert_pem_path, "trace_quic_cert_", cert_pem, cert_pem_len);
    bool wrote_key = write_temp_pem_file(&session->key_pem_path, "trace_quic_key_", key_pem, key_pem_len);

    free(cert_pem);
    free(key_pem);

    if (!wrote_cert || !wrote_key)
    {
        session->last_failure_reason = CQUICHE_FAILURE_INTERNAL_ERROR;
        return false;
    }

    int cert_load_result = quiche_config_load_cert_chain_from_pem_file(
        session->downstream_config,
        session->cert_pem_path
    );
    if (cert_load_result < 0)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_CREATE_FAILED;
        return false;
    }

    int key_load_result = quiche_config_load_priv_key_from_pem_file(
        session->downstream_config,
        session->key_pem_path
    );
    if (key_load_result < 0)
    {
        // Retry with PKCS#8 container label as fallback.
        size_t fallback_key_len = 0;
        char *fallback_key = build_pem_block(
            "PRIVATE KEY",
            config->downstream_private_key_der,
            config->downstream_private_key_der_len,
            &fallback_key_len
        );
        if (fallback_key == NULL ||
            !write_temp_pem_file(&session->key_pem_path, "trace_quic_key_", fallback_key, fallback_key_len) ||
            quiche_config_load_priv_key_from_pem_file(session->downstream_config, session->key_pem_path) < 0)
        {
            free(fallback_key);
            session->last_failure_reason = CQUICHE_FAILURE_SESSION_CREATE_FAILED;
            return false;
        }

        free(fallback_key);
    }

    session->downstream_h3_config = quiche_h3_config_new();
    if (session->downstream_h3_config == NULL)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_CREATE_FAILED;
        return false;
    }

    if (!configure_socket_addresses(session))
    {
        session->last_failure_reason = CQUICHE_FAILURE_INTERNAL_ERROR;
        return false;
    }

    return true;
}

static void close_downstream_runtime(cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return;
    }

    if (session->downstream_h3_conn != NULL)
    {
        quiche_h3_conn_free(session->downstream_h3_conn);
        session->downstream_h3_conn = NULL;
    }

    if (session->downstream_conn != NULL)
    {
        quiche_conn_free(session->downstream_conn);
        session->downstream_conn = NULL;
    }

    if (session->downstream_h3_config != NULL)
    {
        quiche_h3_config_free(session->downstream_h3_config);
        session->downstream_h3_config = NULL;
    }

    if (session->downstream_config != NULL)
    {
        quiche_config_free(session->downstream_config);
        session->downstream_config = NULL;
    }

    close_and_unlink_path(&session->cert_pem_path);
    close_and_unlink_path(&session->key_pem_path);
}

static int ensure_downstream_connection(
    cquiche_mitm_session_t *session,
    const uint8_t *payload,
    size_t payload_len)
{
    if (session == NULL || payload == NULL || payload_len == 0)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    if (session->downstream_conn != NULL)
    {
        return CQUICHE_SUCCESS;
    }

    uint8_t type = 0;
    uint32_t version = 0;

    uint8_t scid[QUICHE_MAX_CONN_ID_LEN];
    size_t scid_len = sizeof(scid);

    uint8_t dcid[QUICHE_MAX_CONN_ID_LEN];
    size_t dcid_len = sizeof(dcid);

    uint8_t odcid[QUICHE_MAX_CONN_ID_LEN];
    size_t odcid_len = sizeof(odcid);

    uint8_t token[128];
    size_t token_len = sizeof(token);

    int rc = quiche_header_info(
        payload,
        payload_len,
        CQUICHE_LOCAL_CONN_ID_LEN,
        &version,
        &type,
        scid,
        &scid_len,
        dcid,
        &dcid_len,
        token,
        &token_len
    );

    if (rc < 0)
    {
        return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
    }

    if (!quiche_version_is_supported(version))
    {
        ssize_t written = quiche_negotiate_version(
            scid,
            scid_len,
            dcid,
            dcid_len,
            session->egress_buffer,
            sizeof(session->egress_buffer)
        );
        if (written > 0)
        {
            enqueue_action(
                session,
                CQUICHE_ACTION_DATAGRAM_TO_CLIENT,
                0,
                CQUICHE_FAILURE_NONE,
                session->egress_buffer,
                (size_t)written,
                NULL,
                0
            );
            session->stats.datagrams_emitted_client += 1;
            return CQUICHE_SUCCESS;
        }

        return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
    }

    if (token_len == 0)
    {
        uint8_t minted_token[CQUICHE_MAX_TOKEN_LEN];
        size_t minted_token_len = 0;
        mint_token(dcid, dcid_len, minted_token, &minted_token_len);

        uint8_t new_cid[CQUICHE_LOCAL_CONN_ID_LEN];
        arc4random_buf(new_cid, sizeof(new_cid));

        ssize_t written = quiche_retry(
            scid,
            scid_len,
            dcid,
            dcid_len,
            new_cid,
            sizeof(new_cid),
            minted_token,
            minted_token_len,
            version,
            session->egress_buffer,
            sizeof(session->egress_buffer)
        );

        if (written <= 0)
        {
            return emit_fallback(session, CQUICHE_FAILURE_HANDSHAKE_FAILED);
        }

        enqueue_action(
            session,
            CQUICHE_ACTION_DATAGRAM_TO_CLIENT,
            0,
            CQUICHE_FAILURE_NONE,
            session->egress_buffer,
            (size_t)written,
            NULL,
            0
        );
        session->stats.datagrams_emitted_client += 1;
        return CQUICHE_SUCCESS;
    }

    if (!validate_token(token, token_len, odcid, &odcid_len))
    {
        return emit_fallback(session, CQUICHE_FAILURE_HANDSHAKE_FAILED);
    }

    session->downstream_conn = quiche_accept(
        dcid,
        dcid_len,
        odcid,
        odcid_len,
        (struct sockaddr *)&session->local_addr,
        session->local_addr_len,
        (struct sockaddr *)&session->peer_addr,
        session->peer_addr_len,
        session->downstream_config
    );

    if (session->downstream_conn == NULL)
    {
        return emit_fallback(session, CQUICHE_FAILURE_SESSION_CREATE_FAILED);
    }

    session->close_action_emitted = false;
    session->authority_retry_emitted = false;
    return CQUICHE_SUCCESS;
}

static int process_downstream_datagram(
    cquiche_mitm_session_t *session,
    const uint8_t *payload,
    size_t payload_len)
{
    if (session == NULL || payload == NULL || payload_len == 0)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    int ensure_result = ensure_downstream_connection(session, payload, payload_len);
    if (ensure_result != CQUICHE_SUCCESS)
    {
        return ensure_result;
    }

    if (session->downstream_conn == NULL)
    {
        // Retry / version-negotiation packet path.
        return CQUICHE_SUCCESS;
    }

    quiche_recv_info recv_info = {
        .from = (struct sockaddr *)&session->peer_addr,
        .from_len = session->peer_addr_len,
        .to = (struct sockaddr *)&session->local_addr,
        .to_len = session->local_addr_len,
    };

    if (payload_len > sizeof(session->ingest_buffer))
    {
        return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
    }

    memcpy(session->ingest_buffer, payload, payload_len);

    ssize_t recv_result = quiche_conn_recv(
        session->downstream_conn,
        session->ingest_buffer,
        payload_len,
        &recv_info
    );

    if (recv_result < 0)
    {
        return emit_fallback(session, CQUICHE_FAILURE_HANDSHAKE_FAILED);
    }

    if (emit_retry_with_authority(session))
    {
        return CQUICHE_SUCCESS;
    }

    if (quiche_conn_is_established(session->downstream_conn) && session->downstream_h3_conn == NULL)
    {
        const uint8_t *alpn = NULL;
        size_t alpn_len = 0;
        quiche_conn_application_proto(session->downstream_conn, &alpn, &alpn_len);
        if (!is_h3_alpn(alpn, alpn_len))
        {
            return emit_fallback(session, CQUICHE_FAILURE_UNSUPPORTED_ALPN);
        }

        session->downstream_h3_conn = quiche_h3_conn_new_with_transport(
            session->downstream_conn,
            session->downstream_h3_config
        );
        if (session->downstream_h3_conn == NULL)
        {
            return emit_fallback(session, CQUICHE_FAILURE_PROTOCOL_ERROR);
        }
    }

    int h3_result = pump_h3_events(session);
    if (h3_result != CQUICHE_SUCCESS)
    {
        return h3_result;
    }

    return drain_downstream_egress(session);
}
#endif

const char *cquiche_version_string(void)
{
#if defined(CQUICHE_WITH_QUICHE)
    const char *linked_version = quiche_version();
    if (linked_version != NULL && linked_version[0] != '\0')
    {
        return linked_version;
    }
#endif

    return "quiche-staged-action-api";
}

bool cquiche_runtime_available(void)
{
#if defined(CQUICHE_WITH_QUICHE)
    return true;
#else
    return false;
#endif
}

int cquiche_http3_engine_state(void)
{
    return cquiche_runtime_available() ? 1 : 0;
}

cquiche_mitm_session_t *cquiche_mitm_session_open_with_config(const cquiche_mitm_open_config_t *config)
{
    if (config == NULL || config->authority == NULL || config->authority[0] == '\0' || config->port == 0)
    {
        return NULL;
    }

    cquiche_mitm_session_t *session = (cquiche_mitm_session_t *)calloc(1, sizeof(cquiche_mitm_session_t));
    if (session == NULL)
    {
        return NULL;
    }

    session->authority = duplicate_string(config->authority);
    if (session->authority == NULL)
    {
        free(session);
        return NULL;
    }

    session->port = config->port;
    session->tunnel_policy_required = config->tunnel_policy_required;
    session->ready = false;
    session->last_failure_reason = CQUICHE_FAILURE_ENGINE_UNAVAILABLE;
    clear_last_failure_detail(session);
    session->next_stream_id = 0;
    memset(&session->stats, 0, sizeof(cquiche_mitm_stats_t));

#if defined(CQUICHE_WITH_QUICHE)
    session->authority_retry_emitted = false;
    if (!initialize_downstream_runtime(session, config))
    {
        close_downstream_runtime(session);
        return session;
    }

    session->ready = true;
    session->last_failure_reason = CQUICHE_FAILURE_NONE;
    clear_last_failure_detail(session);
#else
    (void)config;
#endif

    return session;
}

cquiche_mitm_session_t *cquiche_mitm_session_open(const char *host, uint16_t port)
{
    cquiche_mitm_open_config_t config;
    memset(&config, 0, sizeof(cquiche_mitm_open_config_t));
    config.authority = host;
    config.port = port;
    return cquiche_mitm_session_open_with_config(&config);
}

void cquiche_mitm_session_close(cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return;
    }

#if defined(CQUICHE_WITH_QUICHE)
    close_downstream_runtime(session);
#endif

    clear_action_queue(session);
    free(session->authority);
    free(session);
}

bool cquiche_mitm_session_ready(const cquiche_mitm_session_t *session)
{
    return session != NULL && session->ready;
}

int cquiche_mitm_session_ingest_datagram(
    cquiche_mitm_session_t *session,
    const uint8_t *payload,
    size_t payload_len,
    bool from_client)
{
    if (session == NULL || payload == NULL || payload_len == 0)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    if (from_client)
    {
        session->stats.datagrams_ingested_client += 1;
    }
    else
    {
        session->stats.datagrams_ingested_upstream += 1;
    }

    if (!session->ready)
    {
        if (session->last_failure_reason == CQUICHE_FAILURE_NONE)
        {
            session->last_failure_reason = CQUICHE_FAILURE_ENGINE_UNAVAILABLE;
        }
        return emit_fallback(session, session->last_failure_reason);
    }

#if defined(CQUICHE_WITH_QUICHE)
    if (from_client)
    {
        return process_downstream_datagram(session, payload, payload_len);
    }

    // Upstream leg is handled by Swift transport path in this phase.
    return CQUICHE_SUCCESS;
#else
    (void)payload;
    (void)payload_len;
    (void)from_client;
    return emit_fallback(session, CQUICHE_FAILURE_ENGINE_UNAVAILABLE);
#endif
}

int cquiche_mitm_session_poll_action(
    cquiche_mitm_session_t *session,
    cquiche_action_info_t *action_info,
    uint8_t *payload_buffer,
    size_t payload_buffer_len,
    char *metadata_buffer,
    size_t metadata_buffer_len)
{
    if (session == NULL || action_info == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    cquiche_action_node_t *node = dequeue_action(session);
    if (node == NULL)
    {
        return CQUICHE_POLL_NO_ACTION;
    }

    size_t payload_copy_len = 0;
    if (node->payload_len > 0 && payload_buffer != NULL && payload_buffer_len > 0)
    {
        payload_copy_len = node->payload_len < payload_buffer_len ? node->payload_len : payload_buffer_len;
        memcpy(payload_buffer, node->payload, payload_copy_len);
    }

    size_t metadata_copy_len = 0;
    if (node->metadata_len > 0 && metadata_buffer != NULL && metadata_buffer_len > 0)
    {
        metadata_copy_len = node->metadata_len < metadata_buffer_len - 1 ? node->metadata_len : metadata_buffer_len - 1;
        memcpy(metadata_buffer, node->metadata, metadata_copy_len);
        metadata_buffer[metadata_copy_len] = '\0';
    }
    else if (metadata_buffer != NULL && metadata_buffer_len > 0)
    {
        metadata_buffer[0] = '\0';
    }

    *action_info = node->info;
    action_info->payload_len = payload_copy_len;
    action_info->metadata_len = metadata_copy_len;

    free_action_node(node);
    return CQUICHE_POLL_HAS_ACTION;
}

int cquiche_mitm_session_submit_response(
    cquiche_mitm_session_t *session,
    uint64_t stream_id,
    uint16_t status_code,
    const char *headers_block,
    size_t headers_block_len,
    const uint8_t *body,
    size_t body_len,
    bool fin)
{
    if (session == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    if (!session->ready)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_NOT_READY;
        return CQUICHE_ERROR_SESSION_NOT_READY;
    }

#if defined(CQUICHE_WITH_QUICHE)
    if (session->downstream_conn == NULL || session->downstream_h3_conn == NULL)
    {
        session->last_failure_reason = CQUICHE_FAILURE_SESSION_NOT_READY;
        return CQUICHE_ERROR_SESSION_NOT_READY;
    }

    cquiche_owned_header_list_t header_list = parse_response_header_block(
        headers_block,
        headers_block_len,
        status_code
    );

    if (header_list.count == 0 || header_list.headers == NULL)
    {
        session->last_failure_reason = CQUICHE_FAILURE_INTERNAL_ERROR;
        return CQUICHE_ERROR_INTERNAL;
    }

    int send_response_result = quiche_h3_send_response(
        session->downstream_h3_conn,
        session->downstream_conn,
        stream_id,
        header_list.headers,
        header_list.count,
        fin && body_len == 0
    );
    free_owned_headers(&header_list);

    if (send_response_result < 0)
    {
        session->last_failure_reason = CQUICHE_FAILURE_PROTOCOL_ERROR;
        return CQUICHE_ERROR_INTERNAL;
    }

    if (body_len > 0)
    {
        size_t offset = 0;
        size_t blocked_retries = 0;

        while (offset < body_len)
        {
            const size_t remaining = body_len - offset;

            ssize_t body_sent = quiche_h3_send_body(
                session->downstream_h3_conn,
                session->downstream_conn,
                stream_id,
                body + offset,
                remaining,
                false
            );

            if (body_sent == QUICHE_H3_ERR_DONE || body_sent == QUICHE_H3_ERR_STREAM_BLOCKED || body_sent == 0)
            {
                int drain_result = drain_downstream_egress(session);
                if (drain_result != CQUICHE_SUCCESS)
                {
                    return drain_result;
                }

                blocked_retries += 1;
                if (blocked_retries > 64)
                {
                    session->last_failure_reason = CQUICHE_FAILURE_PROTOCOL_ERROR;
                    return CQUICHE_ERROR_INTERNAL;
                }
                continue;
            }

            if (body_sent < 0)
            {
                session->last_failure_reason = CQUICHE_FAILURE_PROTOCOL_ERROR;
                return CQUICHE_ERROR_INTERNAL;
            }

            blocked_retries = 0;
            offset += (size_t)body_sent;
        }
    }

    if (fin && body_len > 0)
    {
        size_t fin_retries = 0;
        while (true)
        {
            ssize_t fin_sent = quiche_h3_send_body(
                session->downstream_h3_conn,
                session->downstream_conn,
                stream_id,
                (const uint8_t *)"",
                0,
                true
            );

            if (fin_sent == QUICHE_H3_ERR_DONE || fin_sent == QUICHE_H3_ERR_STREAM_BLOCKED)
            {
                int drain_result = drain_downstream_egress(session);
                if (drain_result != CQUICHE_SUCCESS)
                {
                    return drain_result;
                }

                fin_retries += 1;
                if (fin_retries > 64)
                {
                    session->last_failure_reason = CQUICHE_FAILURE_PROTOCOL_ERROR;
                    return CQUICHE_ERROR_INTERNAL;
                }
                continue;
            }

            if (fin_sent < 0)
            {
                session->last_failure_reason = CQUICHE_FAILURE_PROTOCOL_ERROR;
                return CQUICHE_ERROR_INTERNAL;
            }

            break;
        }
    }

    int pump_result = pump_h3_events(session);
    if (pump_result != CQUICHE_SUCCESS)
    {
        return pump_result;
    }

    int drain_result = drain_downstream_egress(session);
    if (drain_result != CQUICHE_SUCCESS)
    {
        return drain_result;
    }

    if (fin)
    {
        session->stats.h3_requests_completed += 1;
    }

    return CQUICHE_SUCCESS;
#else
    (void)stream_id;
    (void)status_code;
    (void)headers_block;
    (void)headers_block_len;
    (void)body;
    (void)body_len;
    (void)fin;
    return CQUICHE_ERROR_SESSION_NOT_READY;
#endif
}

int cquiche_mitm_session_tick(cquiche_mitm_session_t *session, uint64_t now_nanos)
{
    if (session == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    if (!session->ready)
    {
        return CQUICHE_ERROR_SESSION_NOT_READY;
    }

#if defined(CQUICHE_WITH_QUICHE)
    if (session->downstream_conn == NULL)
    {
        return CQUICHE_SUCCESS;
    }

    (void)now_nanos;
    if (quiche_conn_timeout_as_nanos(session->downstream_conn) == 0)
    {
        quiche_conn_on_timeout(session->downstream_conn);

        int pump_result = pump_h3_events(session);
        if (pump_result != CQUICHE_SUCCESS)
        {
            return pump_result;
        }

        return drain_downstream_egress(session);
    }

    return CQUICHE_SUCCESS;
#else
    (void)now_nanos;
    return CQUICHE_ERROR_SESSION_NOT_READY;
#endif
}

int cquiche_mitm_session_last_failure_reason(const cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return CQUICHE_FAILURE_INTERNAL_ERROR;
    }

    return session->last_failure_reason;
}

const char *cquiche_mitm_session_last_failure_detail(const cquiche_mitm_session_t *session)
{
    if (session == NULL)
    {
        return "";
    }

    return session->last_failure_detail;
}

int cquiche_mitm_session_get_stats(
    const cquiche_mitm_session_t *session,
    cquiche_mitm_stats_t *stats)
{
    if (session == NULL || stats == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    *stats = session->stats;
    return CQUICHE_SUCCESS;
}

int cquiche_mitm_session_poll_h3_event(
    cquiche_mitm_session_t *session,
    cquiche_h3_event_info_t *event_info,
    char *headers_buffer,
    size_t headers_buffer_len,
    uint8_t *body_buffer,
    size_t body_buffer_len)
{
    if (session == NULL || event_info == NULL)
    {
        return CQUICHE_ERROR_INVALID_ARGUMENT;
    }

    cquiche_action_info_t action_info;
    memset(&action_info, 0, sizeof(cquiche_action_info_t));

    int poll_status = cquiche_mitm_session_poll_action(
        session,
        &action_info,
        body_buffer,
        body_buffer_len,
        headers_buffer,
        headers_buffer_len
    );

    if (poll_status <= 0)
    {
        return poll_status;
    }

    if (action_info.action_type != CQUICHE_ACTION_HTTP3_REQUEST_HEADERS &&
        action_info.action_type != CQUICHE_ACTION_HTTP3_REQUEST_BODY &&
        action_info.action_type != CQUICHE_ACTION_HTTP3_REQUEST_END)
    {
        return CQUICHE_POLL_NO_ACTION;
    }

    event_info->stream_id = action_info.stream_id;
    event_info->headers_len = action_info.action_type == CQUICHE_ACTION_HTTP3_REQUEST_HEADERS
        ? action_info.metadata_len
        : 0;
    event_info->body_len = action_info.action_type == CQUICHE_ACTION_HTTP3_REQUEST_BODY
        ? action_info.payload_len
        : 0;

    return CQUICHE_POLL_HAS_ACTION;
}
