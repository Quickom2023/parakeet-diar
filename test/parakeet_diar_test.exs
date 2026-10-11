defmodule ParakeetDiarTest do
  use ExUnit.Case, async: false

  @moduletag :parakeet

  setup_all do
    {:ok, ctx} = ParakeetDiar.load(ParakeetDiar.TestHelper.model_path())
    on_exit(fn -> ParakeetDiar.free(ctx) end)
    {:ok, ctx: ctx}
  end

  defp assert_two_speakers(segments) do
    assert Enum.map(segments, & &1.speaker) == ParakeetDiar.TestHelper.expected_speakers()
    assert_in_delta hd(segments).start, 0.52, 0.05
    assert_in_delta List.last(segments).end, 23.6, 0.05
  end

  test "latency/1 maps names to the C API indexes" do
    assert ParakeetDiar.latency(:model) == 0
    assert ParakeetDiar.latency(:low) == 1
    assert ParakeetDiar.latency(:very_low) == 2
    assert ParakeetDiar.latency(:ultra_low) == 3
  end

  test "loads the diarization model", %{ctx: ctx} do
    assert is_reference(ctx)
  end

  test "streams two_speakers.wav in 100 ms pieces", %{ctx: ctx} do
    segments = ParakeetDiar.TestHelper.stream_all(ctx, ParakeetDiar.TestHelper.pcm(), 3200)
    assert_two_speakers(segments)
  end

  test "640-byte pieces give the same result", %{ctx: ctx} do
    segments = ParakeetDiar.TestHelper.stream_all(ctx, ParakeetDiar.TestHelper.pcm(), 640)
    assert_two_speakers(segments)
  end

  test "32000-byte pieces give the same result", %{ctx: ctx} do
    segments = ParakeetDiar.TestHelper.stream_all(ctx, ParakeetDiar.TestHelper.pcm(), 32_000)
    assert_two_speakers(segments)
  end

  test "segments are maps with integer speaker and float times", %{ctx: ctx} do
    segments = ParakeetDiar.TestHelper.stream_all(ctx, ParakeetDiar.TestHelper.pcm(), 3200)

    for seg <- segments do
      assert %{speaker: speaker, start: start, end: finish} = seg
      assert is_integer(speaker)
      assert is_float(start) and is_float(finish)
      assert start <= finish
    end
  end

  test "an empty flush on a fresh stream gives no segments", %{ctx: ctx} do
    {:ok, stream} = ParakeetDiar.open_stream(ctx, :low)
    assert {:ok, []} = ParakeetDiar.feed(stream, <<>>, true)
    assert :ok = ParakeetDiar.close_stream(stream)
  end

  test "an open latency outside 0..3 names is rejected by the NIF", %{ctx: ctx} do
    assert {:error, _} = ParakeetDiar.Nif.stream_begin(ctx, 7)
  end

  test "double close_stream is :ok, and a freed stream reports freed", %{ctx: ctx} do
    {:ok, stream} = ParakeetDiar.open_stream(ctx, :low)
    assert :ok = ParakeetDiar.close_stream(stream)
    assert :ok = ParakeetDiar.close_stream(stream)
    assert {:error, "freed"} = ParakeetDiar.feed(stream, <<0, 0>>)
    assert {:error, "freed"} = ParakeetDiar.active(stream)
    assert {:error, "freed"} = ParakeetDiar.time(stream)
  end

  test "an odd-length pcm binary is an error, and the stream stays usable", %{ctx: ctx} do
    {:ok, stream} = ParakeetDiar.open_stream(ctx, :low)
    assert {:error, "pcm must be whole 16-bit samples"} = ParakeetDiar.feed(stream, <<1, 2, 3>>)
    assert {:ok, _} = ParakeetDiar.feed(stream, <<0, 0>>)
    assert :ok = ParakeetDiar.close_stream(stream)
  end

  test "loading the WAV file as a model is an error" do
    assert {:error, reason} = ParakeetDiar.load(ParakeetDiar.TestHelper.wav_path())
    assert is_binary(reason)
  end

  test "loading a missing path is an error" do
    assert {:error, reason} = ParakeetDiar.load("/nonexistent/model.gguf")
    assert is_binary(reason)
  end

  test "a context can be freed twice, and then refuses new streams" do
    {:ok, ctx} = ParakeetDiar.load(ParakeetDiar.TestHelper.model_path())
    assert :ok = ParakeetDiar.free(ctx)
    assert :ok = ParakeetDiar.free(ctx)
    assert {:error, "freed"} = ParakeetDiar.open_stream(ctx, :low)
  end

  test "a context with an open stream cannot be freed until the stream is closed" do
    {:ok, ctx} = ParakeetDiar.load(ParakeetDiar.TestHelper.model_path())
    {:ok, stream} = ParakeetDiar.open_stream(ctx, :low)
    assert {:error, "streams still open"} = ParakeetDiar.free(ctx)
    assert :ok = ParakeetDiar.close_stream(stream)
    assert :ok = ParakeetDiar.free(ctx)
  end
end
