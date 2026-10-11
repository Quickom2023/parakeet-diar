/*
 * Erlang NIF over parakeet.cpp's live speaker-diarization C API.
 *
 * Two resource types:
 *   - ctx_res:    one loaded diarization model (parakeet_ctx) plus a mutex.
 *                 Every call that touches the context takes the mutex, so a
 *                 context is never used from two threads at once.
 *   - stream_res: one diarization stream. It keeps its context resource alive
 *                 (enif_keep_resource), so the context is never destroyed
 *                 before its streams.
 *
 * Every resource has a `freed` flag. Explicit free functions and the resource
 * destructors both check it, so a double free is safe. All NIFs run as dirty
 * CPU NIFs: feeding audio can take a long time, and the mutex may be held by
 * another dirty job.
 */

#include <erl_nif.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "parakeet_capi.h"

/* pk::shutdown_backend(): frees the process-wide compute backend. The C API
 * does not export it under a C name. On GPU builds it must run after all
 * streams and contexts are freed, and before the OS process exits. */
extern void _ZN2pk16shutdown_backendEv(void);

#define PARAKEET_DIAR_MODEL_KIND 2
#define PARAKEET_DIAR_LATENCY_MAX 3

typedef struct {
  ErlNifMutex *lock;
  parakeet_ctx *ctx; /* NULL once freed */
  int freed;
  int open_streams; /* streams that borrow ctx and are not freed */
} ctx_res;

typedef struct {
  ctx_res *owner; /* held with enif_keep_resource */
  parakeet_diar_stream *stream; /* NULL once freed */
  int freed;
} stream_res;

static ErlNifResourceType *ctx_type = NULL;
static ErlNifResourceType *stream_type = NULL;

/* ---- term helpers -------------------------------------------------------- */

static ERL_NIF_TERM ok_atom(ErlNifEnv *env) {
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM binary_term(ErlNifEnv *env, const char *s) {
  size_t n = s ? strlen(s) : 0;
  ERL_NIF_TERM term;
  unsigned char *p = enif_make_new_binary(env, n, &term);
  if (p == NULL) return enif_make_atom(env, "enomem");
  if (n > 0) memcpy(p, s, n);
  return term;
}

static ERL_NIF_TERM error_term(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"), binary_term(env, reason));
}

static ERL_NIF_TERM ok_term(ErlNifEnv *env, ERL_NIF_TERM value) {
  return enif_make_tuple2(env, ok_atom(env), value);
}

/* The context's last error, valid only until the next library call. Copy it
 * into a term before unlocking. */
static const char *last_error_of(ctx_res *c) {
  const char *msg = parakeet_capi_last_error(c->ctx);
  return msg ? msg : "unknown error";
}

/* ---- resource access ----------------------------------------------------- */

static int get_ctx(ErlNifEnv *env, ERL_NIF_TERM term, ctx_res **out) {
  void *p = NULL;
  if (!enif_get_resource(env, term, ctx_type, &p)) return 0;
  *out = (ctx_res *)p;
  return 1;
}

static int get_stream(ErlNifEnv *env, ERL_NIF_TERM term, stream_res **out) {
  void *p = NULL;
  if (!enif_get_resource(env, term, stream_type, &p)) return 0;
  *out = (stream_res *)p;
  return 1;
}

/* ---- segments ------------------------------------------------------------ */

static ERL_NIF_TERM segment_term(ErlNifEnv *env, const parakeet_diar_segment *seg) {
  ERL_NIF_TERM keys[3] = {
    enif_make_atom(env, "speaker"),
    enif_make_atom(env, "start"),
    enif_make_atom(env, "end"),
  };
  ERL_NIF_TERM vals[3] = {
    enif_make_int(env, seg->speaker),
    enif_make_double(env, (double)seg->start),
    enif_make_double(env, (double)seg->end),
  };
  ERL_NIF_TERM map;
  if (!enif_make_map_from_arrays(env, keys, vals, 3, &map)) {
    return enif_make_atom(env, "badmap");
  }
  return map;
}

/* Builds {:ok, [segment]} from the library's array, then frees the array. The
 * list is built back to front, so no allocation is needed. */
static ERL_NIF_TERM segments_reply(ErlNifEnv *env, parakeet_diar_segment *out, int n) {
  ERL_NIF_TERM list = enif_make_list(env, 0);
  if (out != NULL) {
    for (int i = n - 1; i >= 0; i--) {
      list = enif_make_list_cell(env, segment_term(env, &out[i]), list);
    }
    parakeet_capi_free_diar_segments(out);
  }
  return ok_term(env, list);
}

/* ---- context NIFs -------------------------------------------------------- */

static ERL_NIF_TERM nif_load(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary path;
  if (argc != 1 || !enif_inspect_binary(env, argv[0], &path)) return enif_make_badarg(env);

  for (size_t i = 0; i < path.size; i++) {
    if (path.data[i] == '\0') return error_term(env, "path must not contain NUL");
  }

  char *cpath = enif_alloc(path.size + 1);
  if (cpath == NULL) return error_term(env, "out of memory");
  memcpy(cpath, path.data, path.size);
  cpath[path.size] = '\0';

  parakeet_ctx *ctx = parakeet_capi_load(cpath);
  if (ctx == NULL) {
    const char *why = parakeet_capi_load_error();
    ERL_NIF_TERM reply = error_term(env, why ? why : "load failed");
    enif_free(cpath);
    return reply;
  }
  enif_free(cpath);

  if (parakeet_capi_model_kind(ctx) != PARAKEET_DIAR_MODEL_KIND) {
    parakeet_capi_free(ctx);
    return error_term(env, "not a diarization model");
  }

  ctx_res *res = enif_alloc_resource(ctx_type, sizeof(ctx_res));
  if (res == NULL) {
    parakeet_capi_free(ctx);
    return error_term(env, "out of memory");
  }
  /* Set every field before anything can release the resource. */
  res->lock = NULL;
  res->ctx = ctx;
  res->freed = 0;
  res->open_streams = 0;
  res->lock = enif_mutex_create("parakeet_diar_ctx");
  if (res->lock == NULL) {
    enif_release_resource(res); /* destructor frees ctx */
    return error_term(env, "could not create mutex");
  }

  ERL_NIF_TERM term = enif_make_resource(env, res);
  enif_release_resource(res);
  return ok_term(env, term);
}

static ERL_NIF_TERM nif_free(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ctx_res *c = NULL;
  if (argc != 1 || !get_ctx(env, argv[0], &c)) return enif_make_badarg(env);

  enif_mutex_lock(c->lock);
  ERL_NIF_TERM result;
  if (c->freed) {
    result = ok_atom(env);
  } else if (c->open_streams > 0) {
    result = error_term(env, "streams still open");
  } else {
    parakeet_capi_free(c->ctx);
    c->ctx = NULL;
    c->freed = 1;
    result = ok_atom(env);
  }
  enif_mutex_unlock(c->lock);
  return result;
}

static ERL_NIF_TERM nif_shutdown_backend(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argv;
  if (argc != 0) return enif_make_badarg(env);
  _ZN2pk16shutdown_backendEv();
  return ok_atom(env);
}

/* ---- stream NIFs --------------------------------------------------------- */

static ERL_NIF_TERM nif_stream_begin(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ctx_res *c = NULL;
  int latency = 0;
  if (argc != 2 || !get_ctx(env, argv[0], &c) || !enif_get_int(env, argv[1], &latency)) {
    return enif_make_badarg(env);
  }
  if (latency < 0 || latency > PARAKEET_DIAR_LATENCY_MAX) {
    return error_term(env, "latency must be 0..3");
  }

  enif_mutex_lock(c->lock);
  ERL_NIF_TERM result;
  if (c->freed) {
    result = error_term(env, "freed");
  } else {
    parakeet_diar_stream *s = parakeet_capi_diarize_stream_begin_latency(c->ctx, latency);
    if (s == NULL) {
      result = error_term(env, last_error_of(c));
    } else {
      stream_res *sr = enif_alloc_resource(stream_type, sizeof(stream_res));
      if (sr == NULL) {
        parakeet_capi_diarize_stream_free(s);
        result = error_term(env, "out of memory");
      } else {
        sr->owner = c;
        sr->stream = s;
        sr->freed = 0;
        enif_keep_resource(c);
        c->open_streams++;
        ERL_NIF_TERM term = enif_make_resource(env, sr);
        enif_release_resource(sr);
        result = ok_term(env, term);
      }
    }
  }
  enif_mutex_unlock(c->lock);
  return result;
}

/* Converts s16le bytes to float32 samples in [-1, 1). */
static float *pcm_to_float(const unsigned char *data, size_t n_samples) {
  float *samples = enif_alloc(sizeof(float) * (n_samples > 0 ? n_samples : 1));
  if (samples == NULL) return NULL;
  for (size_t i = 0; i < n_samples; i++) {
    uint16_t u = (uint16_t)(data[2 * i] | ((uint16_t)data[2 * i + 1] << 8));
    int16_t v = (int16_t)u;
    samples[i] = (float)v / 32768.0f;
  }
  return samples;
}

static ERL_NIF_TERM nif_stream_feed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  stream_res *s = NULL;
  ErlNifBinary pcm;
  if (argc != 3 || !get_stream(env, argv[0], &s) || !enif_inspect_binary(env, argv[1], &pcm)) {
    return enif_make_badarg(env);
  }
  int is_last;
  if (enif_is_identical(argv[2], enif_make_atom(env, "true"))) {
    is_last = 1;
  } else if (enif_is_identical(argv[2], enif_make_atom(env, "false"))) {
    is_last = 0;
  } else {
    return enif_make_badarg(env);
  }
  if (pcm.size % 2 != 0) return error_term(env, "pcm must be whole 16-bit samples");

  size_t n_samples = pcm.size / 2;
  if (n_samples > (size_t)INT_MAX) return error_term(env, "pcm is too long");

  float *samples = pcm_to_float(pcm.data, n_samples);
  if (samples == NULL) return error_term(env, "out of memory");

  ctx_res *c = s->owner;
  enif_mutex_lock(c->lock);
  ERL_NIF_TERM result;
  if (s->freed || c->freed) {
    result = error_term(env, "freed");
  } else {
    parakeet_diar_segment *out = NULL;
    int n_out = 0;
    int rc = parakeet_capi_diarize_stream_feed(s->stream, samples, (int)n_samples,
                                               is_last, &out, &n_out);
    if (rc != 0) {
      if (out != NULL) parakeet_capi_free_diar_segments(out);
      result = error_term(env, last_error_of(c));
    } else {
      result = segments_reply(env, out, n_out);
    }
  }
  enif_mutex_unlock(c->lock);
  enif_free(samples);
  return result;
}

static ERL_NIF_TERM nif_stream_active(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  stream_res *s = NULL;
  if (argc != 1 || !get_stream(env, argv[0], &s)) return enif_make_badarg(env);

  ctx_res *c = s->owner;
  enif_mutex_lock(c->lock);
  ERL_NIF_TERM result;
  if (s->freed || c->freed) {
    result = error_term(env, "freed");
  } else {
    parakeet_diar_segment *out = NULL;
    int n_out = 0;
    if (parakeet_capi_diarize_stream_active(s->stream, &out, &n_out) != 0) {
      if (out != NULL) parakeet_capi_free_diar_segments(out);
      result = error_term(env, last_error_of(c));
    } else {
      result = segments_reply(env, out, n_out);
    }
  }
  enif_mutex_unlock(c->lock);
  return result;
}

static ERL_NIF_TERM nif_stream_time(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  stream_res *s = NULL;
  if (argc != 1 || !get_stream(env, argv[0], &s)) return enif_make_badarg(env);

  ctx_res *c = s->owner;
  enif_mutex_lock(c->lock);
  ERL_NIF_TERM result;
  if (s->freed || c->freed) {
    result = error_term(env, "freed");
  } else {
    result = enif_make_double(env, (double)parakeet_capi_diarize_stream_time(s->stream));
  }
  enif_mutex_unlock(c->lock);
  return result;
}

/* Frees the stream (under its context's lock) and releases its hold on the
 * context. Caller must hold the lock. */
static void free_stream_locked(stream_res *s) {
  if (s->freed) return;
  parakeet_capi_diarize_stream_free(s->stream);
  s->stream = NULL;
  s->freed = 1;
  s->owner->open_streams--;
}

static ERL_NIF_TERM nif_stream_free(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  stream_res *s = NULL;
  if (argc != 1 || !get_stream(env, argv[0], &s)) return enif_make_badarg(env);

  ctx_res *c = s->owner;
  enif_mutex_lock(c->lock);
  free_stream_locked(s);
  enif_mutex_unlock(c->lock);
  return ok_atom(env);
}

/* ---- resource destructors ------------------------------------------------ */

static void ctx_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  ctx_res *c = (ctx_res *)obj;
  if (c->ctx != NULL && !c->freed) parakeet_capi_free(c->ctx);
  c->ctx = NULL;
  if (c->lock != NULL) enif_mutex_destroy(c->lock);
}

static void stream_dtor(ErlNifEnv *env, void *obj) {
  (void)env;
  stream_res *s = (stream_res *)obj;
  if (s->owner == NULL) return;
  ctx_res *c = s->owner;
  enif_mutex_lock(c->lock);
  free_stream_locked(s);
  enif_mutex_unlock(c->lock);
  enif_release_resource(c); /* the hold taken in stream_begin */
  s->owner = NULL;
}

/* ---- NIF table and init -------------------------------------------------- */

static ErlNifFunc nif_funcs[] = {
  {"load", 1, nif_load, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"free", 1, nif_free, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"stream_begin", 2, nif_stream_begin, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"stream_feed", 3, nif_stream_feed, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"stream_active", 1, nif_stream_active, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"stream_time", 1, nif_stream_time, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"stream_free", 1, nif_stream_free, ERL_NIF_DIRTY_JOB_CPU_BOUND},
  {"shutdown_backend", 0, nif_shutdown_backend, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

static int nif_on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ctx_type = enif_open_resource_type(env, NULL, "parakeet_diar_ctx", ctx_dtor,
                                     ERL_NIF_RT_CREATE, NULL);
  if (ctx_type == NULL) return 1;
  stream_type = enif_open_resource_type(env, NULL, "parakeet_diar_stream", stream_dtor,
                                        ERL_NIF_RT_CREATE, NULL);
  if (stream_type == NULL) return 1;
  return 0;
}

ERL_NIF_INIT(Elixir.ParakeetDiar.Nif, nif_funcs, nif_on_load, NULL, NULL, NULL)
