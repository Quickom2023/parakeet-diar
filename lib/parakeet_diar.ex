defmodule ParakeetDiar do
  @moduledoc """
  Live speaker diarization with parakeet.cpp (NVIDIA Nemotron-3-Diarization),
  as an Erlang NIF.

  A context holds one loaded model. A stream is one audio source diarized in
  cache-aware streaming mode, so speaker numbers stay stable for its whole life.

  Audio is 16 kHz mono signed 16-bit little-endian PCM. Segments are maps
  `%{speaker: integer, start: float, end: float}`, in seconds from the start
  of the stream.

  Lifetime rules:

    * free every stream before its context;
    * a context must not be used from two threads at once. The NIF serializes
      calls with a mutex, but `ParakeetDiar.Server` is the simplest owner;
    * `shutdown_backend/0` only once, before the OS process exits (on GPU
      builds, otherwise the CUDA driver aborts the process).

  Use `ParakeetDiar.Server` for a supervised, cap-limited set of streams.
  """

  @doc "Loads a diarization model. `{:ok, ctx}` or `{:error, reason}`."
  def load(path) when is_binary(path), do: ParakeetDiar.Nif.load(path)

  @doc "Frees a context. Free its streams first."
  def free(ctx), do: ParakeetDiar.Nif.free(ctx)

  @doc """
  Opens a stream. `latency` is one of `:model` (21.12 s), `:low` (1.04 s),
  `:very_low` (0.64 s) or `:ultra_low` (0.32 s).
  """
  def open_stream(ctx, latency) do
    ParakeetDiar.Nif.stream_begin(ctx, latency(latency))
  end

  @doc """
  Feeds s16le PCM bytes. Pass `is_last = true` (with `<<>>` if there is no audio
  left) to flush the stream. Returns the segments that ended since the last call.
  """
  def feed(stream, pcm, is_last \\ false) when is_binary(pcm) do
    ParakeetDiar.Nif.stream_feed(stream, pcm, is_last)
  end

  @doc "Returns the segments still open (who is speaking now)."
  def active(stream), do: ParakeetDiar.Nif.stream_active(stream)

  @doc "Seconds of the stream diarized so far."
  def time(stream), do: ParakeetDiar.Nif.stream_time(stream)

  @doc "Frees a stream. Safe to call twice."
  def close_stream(stream), do: ParakeetDiar.Nif.stream_free(stream)

  @doc "Frees parakeet's process-wide backend. Call once, before the VM exits."
  def shutdown_backend, do: ParakeetDiar.Nif.shutdown_backend()

  @doc "Maps a latency name to the C API's latency index."
  def latency(:model), do: 0
  def latency(:low), do: 1
  def latency(:very_low), do: 2
  def latency(:ultra_low), do: 3
end
