/* Research only. The gate is a deterministic stand-in for a blocked open. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <erl_nif.h>

#define MAX_BATCH 128
#define MAX_NAME 1024

typedef struct {
    DIR *dir;
    ErlNifMutex *lock;
} cursor;

static ErlNifResourceType *cursor_type;
static int gate[2];
static atomic_int gate_state;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name)
{
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static const char *reason(int code)
{
    switch (code) {
    case EACCES: return "eacces";
    case EPERM: return "eperm";
    case ENOENT: return "enoent";
    case ENOTDIR: return "enotdir";
    default: return "eio";
    }
}

static void destroy_cursor(ErlNifEnv *env, void *object)
{
    (void) env;
    cursor *c = object;
    /* Prototype fallback only: production must not close on a normal scheduler. */
    if (c->dir) closedir(c->dir);
    if (c->lock) enif_mutex_destroy(c->lock);
}

static ERL_NIF_TERM open_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    char path[4096];
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) || bin.size >= sizeof path ||
        memchr(bin.data, '\0', bin.size)) return enif_make_badarg(env);
    memcpy(path, bin.data, bin.size);
    path[bin.size] = '\0';

    if (enif_is_identical(argv[1], atom(env, "gated"))) {
        int expected = 0;
        if (!atomic_compare_exchange_strong(&gate_state, &expected, 1))
            return error(env, "busy");
        struct pollfd fd = {.fd = gate[0], .events = POLLIN};
        int ready = poll(&fd, 1, 8000);
        atomic_store(&gate_state, 3);
        if (ready == 0) return error(env, "timeout");
        if (ready < 0 || !(fd.revents & POLLIN)) return error(env, "eio");
    } else if (enif_is_identical(argv[1], atom(env, "denied"))) {
        return error(env, "eacces");
    } else if (!enif_is_identical(argv[1], atom(env, "normal"))) {
        return enif_make_badarg(env);
    }

    DIR *dir = opendir(path);
    if (!dir) return error(env, reason(errno));
    cursor *c = enif_alloc_resource(cursor_type, sizeof *c);
    if (!c) {
        closedir(dir);
        return error(env, "enomem");
    }
    c->dir = dir;
    c->lock = enif_mutex_create("workspace_scan_cursor");
    if (!c->lock) {
        enif_release_resource(c);
        return error(env, "enomem");
    }
    ERL_NIF_TERM handle = enif_make_resource(env, c);
    enif_release_resource(c);
    return enif_make_tuple2(env, atom(env, "ok"), handle);
}

static const char *entry_type(unsigned char d_type)
{
    switch (d_type) {
    case DT_DIR: return "directory";
    case DT_LNK: return "symlink";
    case DT_REG: return "regular";
    default: return "unknown";
    }
}

static ERL_NIF_TERM next_batch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    cursor *c;
    unsigned limit;
    if (!enif_get_resource(env, argv[0], cursor_type, (void **) &c) ||
        !enif_get_uint(env, argv[1], &limit) || limit == 0 || limit > MAX_BATCH)
        return enif_make_badarg(env);
    if (enif_mutex_trylock(c->lock) != 0) return error(env, "busy");

    ERL_NIF_TERM result;
    if (!c->dir) {
        result = error(env, "closed");
    } else {
        ERL_NIF_TERM rows[MAX_BATCH];
        unsigned count = 0;
        const char *status = "more";
        const char *failure = NULL;
        /* Budget visited entries, not only returned rows. */
        for (unsigned i = 0; i < limit; ++i) {
            errno = 0;
            struct dirent *entry = readdir(c->dir);
            if (!entry) {
                if (errno) failure = reason(errno);
                else status = "eof";
                break;
            }
            const char *name = entry->d_name;
            if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
            size_t length = strlen(name);
            if (length > MAX_NAME) {
                failure = "enametoolong";
                break;
            }
            ERL_NIF_TERM binary;
            unsigned char *bytes = enif_make_new_binary(env, length, &binary);
            if (!bytes) {
                failure = "enomem";
                break;
            }
            memcpy(bytes, name, length);
            rows[count++] = enif_make_tuple2(env, binary, atom(env, entry_type(entry->d_type)));
        }
        result = failure ? error(env, failure) :
            enif_make_tuple3(env, atom(env, "ok"), enif_make_list_from_array(env, rows, count),
                             atom(env, status));
    }
    enif_mutex_unlock(c->lock);
    return result;
}

static ERL_NIF_TERM close_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc;
    cursor *c;
    if (!enif_get_resource(env, argv[0], cursor_type, (void **) &c))
        return enif_make_badarg(env);
    if (enif_mutex_trylock(c->lock) != 0) return error(env, "busy");
    int result = c->dir ? closedir(c->dir) : 0;
    int code = errno;
    c->dir = NULL;
    enif_mutex_unlock(c->lock);
    return result == 0 ? atom(env, "ok") : error(env, reason(code));
}

static ERL_NIF_TERM gate_waiting(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc; (void) argv;
    return atom(env, atomic_load(&gate_state) == 1 ? "true" : "false");
}

static ERL_NIF_TERM release_gate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void) argc; (void) argv;
    int expected = 1;
    if (!atomic_compare_exchange_strong(&gate_state, &expected, 2))
        return error(env, "not_waiting");
    return write(gate[1], "x", 1) == 1 ? atom(env, "ok") : error(env, "eio");
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info)
{
    (void) priv; (void) info;
    cursor_type = enif_open_resource_type(env, NULL, "workspace_scan_cursor", destroy_cursor,
                                         ERL_NIF_RT_CREATE, NULL);
    if (!cursor_type || pipe(gate) != 0) return -1;
    if (fcntl(gate[1], F_SETFL, O_NONBLOCK) != 0) {
        close(gate[0]);
        close(gate[1]);
        return -1;
    }
    atomic_init(&gate_state, 0);
    return 0;
}

static void unload(ErlNifEnv *env, void *priv)
{
    (void) env; (void) priv;
    close(gate[0]);
    close(gate[1]);
}

static ErlNifFunc funcs[] = {
    {"open", 2, open_dir, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"next", 2, next_batch, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, close_dir, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"gate_waiting", 0, gate_waiting, 0},
    {"release_gate", 0, release_gate, 0}
};

ERL_NIF_INIT(workspace_scan_probe, funcs, load, NULL, NULL, unload)
