defmodule ParakeetDiar.Nif do
  @moduledoc """
  Raw NIF bindings to `c_src/parakeet_diar_nif.c`. Use `ParakeetDiar` instead.

  The shared object is loaded from `priv/parakeet_diar_nif.so` by `@on_load`.
  Every function here is a dirty CPU NIF. A stream call that finds its context
  or stream already freed returns `{:error, "freed"}`. Free calls are
  idempotent and return `:ok`.
  """

  @on_load :init_nif

  @doc false
  def init_nif do
    case :code.priv_dir(:parakeet_diar) do
      {:error, reason} ->
        {:error, reason}

      dir ->
        :erlang.load_nif(:filename.join(dir, ~c"parakeet_diar_nif"), 0)
    end
  end

  @doc "Loads a diarization GGUF. `{:ok, ctx}` or `{:error, reason}`."
  def load(_path), do: nif_error()

  @doc "Frees a context. Refused with `{:error, \"streams still open\"}` while streams live."
  def free(_ctx), do: nif_error()

  @doc "Opens a stream on a context. Latency is 0 (model, 21.12 s) to 3 (ultra low, 0.32 s)."
  def stream_begin(_ctx, _latency), do: nif_error()

  @doc "Feeds 16 kHz mono s16le bytes. Returns the segments that ended since the last call."
  def stream_feed(_stream, _pcm, _is_last), do: nif_error()

  @doc "Returns the segments still open, as of `stream_time/1`."
  def stream_active(_stream), do: nif_error()

  @doc "Seconds of the stream diarized so far."
  def stream_time(_stream), do: nif_error()

  @doc "Frees a stream. Idempotent."
  def stream_free(_stream), do: nif_error()

  @doc "Frees parakeet's process-wide compute backend. Call only before the OS process exits."
  def shutdown_backend, do: nif_error()

  defp nif_error, do: :erlang.nif_error(:nif_not_loaded)
end
