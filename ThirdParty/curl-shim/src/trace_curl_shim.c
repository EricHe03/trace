#include "trace_curl_shim.h"
#include "trace_curl_vendor.h"

#include <curl/curl.h>
#include <curl/curlver.h>

#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Symbols provided by curl's tool sources (compiled in CCurlVendor). */
typedef char *trace_argv_item_t;
extern CURLcode globalconf_init(void);
extern void globalconf_free(void);
extern CURLcode operate(int argc, trace_argv_item_t argv[]);
extern int parse_args(int argc, trace_argv_item_t argv[]);
extern void tool_init_stderr(void);

static pthread_mutex_t g_runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_protocol_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_last_error[512] = {0};
static char g_version_string[640] = {0};
static char *g_protocols_csv = NULL;

static void set_last_error(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vsnprintf(g_last_error, sizeof(g_last_error), format, args);
    va_end(args);
}

static int copy_stream_to_cstring(FILE *stream, char **out)
{
    long file_size;
    size_t bytes_read;
    char *buffer;

    if(!stream || !out) {
        return -1;
    }

    if(fseek(stream, 0L, SEEK_END) != 0) {
        return -1;
    }

    file_size = ftell(stream);
    if(file_size < 0) {
        return -1;
    }

    if(fseek(stream, 0L, SEEK_SET) != 0) {
        return -1;
    }

    buffer = malloc((size_t)file_size + 1U);
    if(!buffer) {
        return -1;
    }

    bytes_read = fread(buffer, 1U, (size_t)file_size, stream);
    if(ferror(stream)) {
        free(buffer);
        return -1;
    }

    buffer[bytes_read] = '\0';
    *out = buffer;
    return 0;
}

static trace_argv_item_t *build_tool_argv(int32_t argc, const char *const *argv)
{
    int32_t index;
    int32_t count = argc + 1;
    trace_argv_item_t *tool_argv = calloc((size_t)count + 1U, sizeof(trace_argv_item_t));

    if(!tool_argv) {
        return NULL;
    }

    tool_argv[0] = strdup("curl");
    if(!tool_argv[0]) {
        free(tool_argv);
        return NULL;
    }

    for(index = 0; index < argc; index++) {
        const char *value = argv[index] ? argv[index] : "";
        tool_argv[(size_t)index + 1U] = strdup(value);
        if(!tool_argv[(size_t)index + 1U]) {
            int32_t cleanup_index;
            for(cleanup_index = 0; cleanup_index <= index; cleanup_index++) {
                free(tool_argv[cleanup_index]);
            }
            free(tool_argv);
            return NULL;
        }
    }

    tool_argv[count] = NULL;
    return tool_argv;
}

static void free_tool_argv(trace_argv_item_t *tool_argv)
{
    size_t index = 0;

    if(!tool_argv) {
        return;
    }

    while(tool_argv[index]) {
        free(tool_argv[index]);
        index++;
    }

    free(tool_argv);
}

static int execute_locked(int32_t argc, const char *const *argv, trace_curl_execute_result *result)
{
    FILE *stdout_file = NULL;
    FILE *stderr_file = NULL;
    int stdout_fd = -1;
    int stderr_fd = -1;
    int saved_stdout = -1;
    int saved_stderr = -1;
    int status = -1;
    CURLcode init_result;
    CURLcode run_result = CURLE_OK;
    trace_argv_item_t *tool_argv = NULL;

    saved_stdout = dup(STDOUT_FILENO);
    saved_stderr = dup(STDERR_FILENO);
    if(saved_stdout < 0 || saved_stderr < 0) {
        set_last_error("Failed to duplicate stdio descriptors");
        goto cleanup;
    }

    stdout_file = tmpfile();
    stderr_file = tmpfile();
    if(!stdout_file || !stderr_file) {
        set_last_error("Failed to create temporary output files");
        goto cleanup;
    }

    stdout_fd = fileno(stdout_file);
    stderr_fd = fileno(stderr_file);
    if(stdout_fd < 0 || stderr_fd < 0) {
        set_last_error("Failed to obtain temporary file descriptors");
        goto cleanup;
    }

    if(fflush(stdout) != 0 || fflush(stderr) != 0) {
        set_last_error("Failed to flush process output streams");
        goto cleanup;
    }

    if(dup2(stdout_fd, STDOUT_FILENO) < 0 || dup2(stderr_fd, STDERR_FILENO) < 0) {
        set_last_error("Failed to redirect process output streams");
        goto cleanup;
    }

    tool_init_stderr();

    tool_argv = build_tool_argv(argc, argv);
    if(!tool_argv) {
        set_last_error("Failed to allocate argv for curl runtime");
        goto cleanup;
    }

    init_result = globalconf_init();
    if(init_result != CURLE_OK) {
        set_last_error("curl global initialization failed: %s", curl_easy_strerror(init_result));
        goto cleanup;
    }

    run_result = operate(argc + 1, tool_argv);
    globalconf_free();

    if(fflush(stdout) != 0 || fflush(stderr) != 0) {
        set_last_error("Failed to flush redirected streams");
        goto cleanup;
    }

    if(dup2(saved_stdout, STDOUT_FILENO) < 0 || dup2(saved_stderr, STDERR_FILENO) < 0) {
        set_last_error("Failed to restore process output streams");
        goto cleanup;
    }

    if(copy_stream_to_cstring(stdout_file, &result->stdout_utf8) != 0) {
        set_last_error("Failed to read captured stdout");
        goto cleanup;
    }

    if(copy_stream_to_cstring(stderr_file, &result->stderr_utf8) != 0) {
        set_last_error("Failed to read captured stderr");
        goto cleanup;
    }

    result->exit_code = (int32_t)run_result;
    status = 0;

cleanup:
    if(status != 0) {
        if(saved_stdout >= 0) {
            (void)dup2(saved_stdout, STDOUT_FILENO);
        }
        if(saved_stderr >= 0) {
            (void)dup2(saved_stderr, STDERR_FILENO);
        }
    }

    if(saved_stdout >= 0) {
        (void)close(saved_stdout);
    }
    if(saved_stderr >= 0) {
        (void)close(saved_stderr);
    }

    if(stdout_file) {
        fclose(stdout_file);
    }
    if(stderr_file) {
        fclose(stderr_file);
    }

    free_tool_argv(tool_argv);

    return status;
}

static int parse_locked(int32_t argc, const char *const *argv, trace_curl_parse_result *result)
{
    FILE *stderr_file = NULL;
    int stderr_fd = -1;
    int saved_stderr = -1;
    int status = -1;
    bool global_initialized = false;
    CURLcode init_result;
    int parse_result;
    trace_argv_item_t *tool_argv = NULL;

    saved_stderr = dup(STDERR_FILENO);
    if(saved_stderr < 0) {
        set_last_error("Failed to duplicate stderr descriptor");
        goto cleanup;
    }

    stderr_file = tmpfile();
    if(!stderr_file) {
        set_last_error("Failed to create temporary stderr file");
        goto cleanup;
    }

    stderr_fd = fileno(stderr_file);
    if(stderr_fd < 0) {
        set_last_error("Failed to obtain temporary stderr descriptor");
        goto cleanup;
    }

    if(fflush(stderr) != 0) {
        set_last_error("Failed to flush stderr stream");
        goto cleanup;
    }

    if(dup2(stderr_fd, STDERR_FILENO) < 0) {
        set_last_error("Failed to redirect stderr stream");
        goto cleanup;
    }

    tool_init_stderr();

    tool_argv = build_tool_argv(argc, argv);
    if(!tool_argv) {
        set_last_error("Failed to allocate argv for curl preflight parser");
        goto cleanup;
    }

    init_result = globalconf_init();
    if(init_result != CURLE_OK) {
        set_last_error("curl global initialization failed: %s", curl_easy_strerror(init_result));
        goto cleanup;
    }
    global_initialized = true;

    parse_result = parse_args(argc + 1, tool_argv);
    result->parameter_error = (int32_t)parse_result;
    result->url_count = -1;
    result->transfer_count = -1;

    globalconf_free();
    global_initialized = false;

    if(fflush(stderr) != 0) {
        set_last_error("Failed to flush redirected stderr stream");
        goto cleanup;
    }

    if(dup2(saved_stderr, STDERR_FILENO) < 0) {
        set_last_error("Failed to restore stderr stream");
        goto cleanup;
    }

    if(copy_stream_to_cstring(stderr_file, &result->stderr_utf8) != 0) {
        set_last_error("Failed to read captured preflight stderr");
        goto cleanup;
    }

    status = 0;

cleanup:
    if(global_initialized) {
        globalconf_free();
    }

    if(status != 0 && saved_stderr >= 0) {
        (void)dup2(saved_stderr, STDERR_FILENO);
    }

    if(saved_stderr >= 0) {
        (void)close(saved_stderr);
    }

    if(stderr_file) {
        fclose(stderr_file);
    }

    free_tool_argv(tool_argv);
    return status;
}

static const char *build_protocols_csv_locked(void)
{
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    size_t length = 0;
    size_t index;

    if(!info || !info->protocols || !info->protocols[0]) {
        g_protocols_csv = strdup("http,https");
        return g_protocols_csv ? g_protocols_csv : "http,https";
    }

    for(index = 0; info->protocols[index]; index++) {
        const char *protocol = info->protocols[index];
        length += strlen(protocol);
        if(index > 0) {
            length += 1U;
        }
    }

    g_protocols_csv = malloc(length + 1U);
    if(!g_protocols_csv) {
        return "http,https";
    }

    g_protocols_csv[0] = '\0';
    for(index = 0; info->protocols[index]; index++) {
        if(index > 0) {
            strcat(g_protocols_csv, ",");
        }
        strcat(g_protocols_csv, info->protocols[index]);
    }

    return g_protocols_csv;
}

int32_t trace_curl_runtime_available(void)
{
    return 1;
}

int32_t trace_curl_runtime_supports_full_option_parity(void)
{
    return 1;
}

const char *trace_curl_runtime_backend_name(void)
{
    return "CCurlShim(vendored,in-process)";
}

const char *trace_curl_runtime_supported_protocols_csv(void)
{
    const char *csv;

    pthread_mutex_lock(&g_protocol_lock);
    if(g_protocols_csv) {
        csv = g_protocols_csv;
    } else {
        csv = build_protocols_csv_locked();
    }
    pthread_mutex_unlock(&g_protocol_lock);

    return csv ? csv : "http,https";
}

const char *trace_curl_runtime_version_string(void)
{
    const char *runtime_version = curl_version();

    pthread_mutex_lock(&g_protocol_lock);
    snprintf(
        g_version_string,
        sizeof(g_version_string),
        "%s (%s @ %s)",
        runtime_version ? runtime_version : LIBCURL_VERSION,
        TRACE_CURL_VENDOR_TAG,
        TRACE_CURL_VENDOR_COMMIT
    );
    pthread_mutex_unlock(&g_protocol_lock);

    return g_version_string;
}

int32_t trace_curl_execute_argv(
    int32_t argc,
    const char *const *argv,
    trace_curl_execute_result *result
)
{
    int32_t status;

    if(!result) {
        set_last_error("Result container is missing");
        return -1;
    }

    result->exit_code = -1;
    result->stdout_utf8 = NULL;
    result->stderr_utf8 = NULL;

    if(argc <= 0 || !argv) {
        set_last_error("Runtime received an empty argument vector");
        return -1;
    }

    pthread_mutex_lock(&g_runtime_lock);
    status = execute_locked(argc, argv, result);
    pthread_mutex_unlock(&g_runtime_lock);

    return status;
}

void trace_curl_execute_result_dispose(trace_curl_execute_result *result)
{
    if(!result) {
        return;
    }

    free(result->stdout_utf8);
    free(result->stderr_utf8);
    result->stdout_utf8 = NULL;
    result->stderr_utf8 = NULL;
    result->exit_code = 0;
}

int32_t trace_curl_parse_argv(
    int32_t argc,
    const char *const *argv,
    trace_curl_parse_result *result
)
{
    int32_t status;

    if(!result) {
        set_last_error("Parse result container is missing");
        return -1;
    }

    result->parameter_error = -1;
    result->transfer_count = 0;
    result->url_count = 0;
    result->stderr_utf8 = NULL;

    if(argc <= 0 || !argv) {
        set_last_error("Runtime parser received an empty argument vector");
        return -1;
    }

    pthread_mutex_lock(&g_runtime_lock);
    status = parse_locked(argc, argv, result);
    pthread_mutex_unlock(&g_runtime_lock);

    return status;
}

void trace_curl_parse_result_dispose(trace_curl_parse_result *result)
{
    if(!result) {
        return;
    }

    free(result->stderr_utf8);
    result->stderr_utf8 = NULL;
    result->parameter_error = 0;
    result->transfer_count = 0;
    result->url_count = 0;
}

const char *trace_curl_runtime_last_error(void)
{
    if(g_last_error[0] == '\0') {
        return "Unknown runtime error";
    }
    return g_last_error;
}
