defmodule ParakeetDiar.TestHelper do
  @moduledoc false

  @default_model Path.expand("../../parakeet.cpp/models/nemotron-3-diarization-f16.gguf", __DIR__)
  @default_wav Path.expand("../../parakeet.cpp/tests/fixtures/two_speakers.wav", __DIR__)

  @wav_header_bytes 44

  def model_path, do: System.get_env("PARAKEET_TEST_MODEL", @default_model)
  def wav_path, do: System.get_env("PARAKEET_TEST_WAV", @default_wav)

  # The WAV file's PCM payload: s16le mono 16 kHz, after the 44-byte header.
  def pcm do
    wav = File.read!(wav_path())
    binary_part(wav, @wav_header_bytes, byte_size(wav) - @wav_header_bytes)
  end

  def chunks(<<>>, _size), do: []
  def chunks(bin, size) when byte_size(bin) <= size, do: [bin]

  def chunks(bin, size) do
    <<head::binary-size(size), rest::binary>> = bin
    [head | chunks(rest, size)]
  end

  # Streams `pcm` in `piece`-byte writes, then flushes. Returns every segment in
  # the order the library ended them.
  def stream_all(ctx, pcm, piece, latency \\ :low) do
    {:ok, stream} = ParakeetDiar.open_stream(ctx, latency)

    segments =
      Enum.flat_map(chunks(pcm, piece), fn chunk ->
        {:ok, segs} = ParakeetDiar.feed(stream, chunk)
        segs
      end)

    {:ok, tail} = ParakeetDiar.feed(stream, <<>>, true)
    :ok = ParakeetDiar.close_stream(stream)
    segments ++ tail
  end

  def expected_speakers, do: [0, 1, 1, 0, 1]
end

ExUnit.start()
