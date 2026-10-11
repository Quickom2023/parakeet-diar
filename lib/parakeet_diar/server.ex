defmodule ParakeetDiar.Server do
  @moduledoc """
  Owns one diarization model and a set of streams, keyed by tag.

  Options:

    * `model:` (required), path to the diarization GGUF;
    * `max_streams:` (default 8), how many streams may be open at once. Past it,
      `open/3` returns `{:error, :busy}`;
    * `name:` (optional), registered name.

  Stream calls run inside the server, one at a time, so the context is never used
  from two threads. A flush (`feed(server, tag, <<>>, true)`) does not close the
  stream; call `close/2` when the stream is finished.

  On termination (the server traps exits) every stream is freed, then the model,
  then the process-wide backend.
  """

  use GenServer

  @default_max_streams 8
  @latencies [:model, :low, :very_low, :ultra_low]

  def start_link(opts) do
    GenServer.start_link(ParakeetDiar.Server, opts, Keyword.take(opts, [:name]))
  end

  @doc "Opens a stream under `tag`. `latency` is one of the `ParakeetDiar.latency/1` names."
  def open(server, tag, latency) do
    GenServer.call(server, {:open, tag, latency}, :infinity)
  end

  @doc "Feeds s16le PCM to the stream under `tag`. Returns the segments that ended."
  def feed(server, tag, pcm, is_last \\ false) do
    GenServer.call(server, {:feed, tag, pcm, is_last}, :infinity)
  end

  @doc """
  Feeds `pcm` (s16le) to the stream under `tag` and tells all of where it is:
  `{:ok, %{ended: segments, active: segments, time: seconds}}` — one call per
  piece of audio, rather than three.
  """
  def step(server, tag, pcm, is_last) do
    GenServer.call(server, {:step, tag, pcm, is_last}, :infinity)
  end

  @doc "Returns the segments still open on the stream under `tag`."
  def active(server, tag) do
    GenServer.call(server, {:active, tag}, :infinity)
  end

  @doc "Frees the stream under `tag`."
  def close(server, tag) do
    GenServer.call(server, {:close, tag}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case ParakeetDiar.load(Keyword.fetch!(opts, :model)) do
      {:ok, ctx} ->
        max = Keyword.get(opts, :max_streams, @default_max_streams)
        # owners: pid → monitor ref; a stream's owner is the process that opened
        # it, and its streams are freed when it goes.
        {:ok, %{ctx: ctx, streams: %{}, owners: %{}, max_streams: max}}

      {:error, reason} ->
        {:stop, {:load_failed, reason}}
    end
  end

  @impl true
  def handle_call({:open, tag, latency}, {owner, _ref}, state) when latency in @latencies do
    cond do
      Map.has_key?(state.streams, tag) ->
        {:reply, {:error, :already_open}, state}

      map_size(state.streams) >= state.max_streams ->
        {:reply, {:error, :busy}, state}

      true ->
        case ParakeetDiar.open_stream(state.ctx, latency) do
          {:ok, stream} ->
            state = watch(state, owner)
            {:reply, :ok, put_in(state.streams[tag], {stream, owner})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:open, _tag, _latency}, _from, state) do
    {:reply, {:error, :bad_latency}, state}
  end

  def handle_call({:feed, tag, pcm, is_last}, _from, state) do
    with_stream(state, tag, fn stream -> ParakeetDiar.feed(stream, pcm, is_last) end)
  end

  def handle_call({:step, tag, pcm, is_last}, _from, state) do
    with_stream(state, tag, fn stream ->
      stream
      |> ParakeetDiar.feed(pcm, is_last)
      |> case do
        {:ok, ended} ->
          {:ok, active} = ParakeetDiar.active(stream)
          {:ok, %{ended: ended, active: active, time: ParakeetDiar.time(stream)}}

        error ->
          error
      end
    end)
  end

  def handle_call({:active, tag}, _from, state) do
    with_stream(state, tag, &ParakeetDiar.active/1)
  end

  def handle_call({:close, tag}, _from, state) do
    case Map.fetch(state.streams, tag) do
      {:ok, {stream, _owner}} ->
        ParakeetDiar.close_stream(stream)
        {:reply, :ok, %{state | streams: Map.delete(state.streams, tag)}}

      :error ->
        {:reply, {:error, :unknown_tag}, state}
    end
  end

  # An owner gone without closing: its streams are freed, their places given back.
  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    {gone, kept} = Enum.split_with(state.streams, fn {_tag, {_stream, by}} -> by == owner end)
    Enum.each(gone, fn {_tag, {stream, _by}} -> ParakeetDiar.close_stream(stream) end)
    {:noreply, %{state | streams: Map.new(kept), owners: Map.delete(state.owners, owner)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.streams, fn {_tag, {stream, _owner}} -> ParakeetDiar.close_stream(stream) end)
    ParakeetDiar.free(state.ctx)
    ParakeetDiar.shutdown_backend()
    :ok
  end

  defp watch(state, owner) do
    if Map.has_key?(state.owners, owner),
      do: state,
      else: %{state | owners: Map.put(state.owners, owner, Process.monitor(owner))}
  end

  defp with_stream(state, tag, fun) do
    case Map.fetch(state.streams, tag) do
      {:ok, {stream, _owner}} -> {:reply, fun.(stream), state}
      :error -> {:reply, {:error, :unknown_tag}, state}
    end
  end
end
