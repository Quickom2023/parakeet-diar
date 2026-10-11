defmodule ParakeetDiar.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :parakeet

  defp model, do: ParakeetDiar.TestHelper.model_path()

  defp start_server(opts) do
    {:ok, pid} = ParakeetDiar.Server.start_link(Keyword.put(opts, :model, model()))
    pid
  end

  test "streams through the server give the expected speakers" do
    server = start_server([])
    assert :ok = ParakeetDiar.Server.open(server, :mic, :low)

    segments =
      ParakeetDiar.TestHelper.chunks(ParakeetDiar.TestHelper.pcm(), 3200)
      |> Enum.flat_map(fn chunk ->
        {:ok, segs} = ParakeetDiar.Server.feed(server, :mic, chunk)
        segs
      end)

    {:ok, tail} = ParakeetDiar.Server.feed(server, :mic, <<>>, true)
    assert Enum.map(segments ++ tail, & &1.speaker) == ParakeetDiar.TestHelper.expected_speakers()
    assert :ok = ParakeetDiar.Server.close(server, :mic)
    GenServer.stop(server)
  end

  test "the stream cap returns {:error, :busy}, and closing a stream frees its place" do
    server = start_server(max_streams: 2)

    assert :ok = ParakeetDiar.Server.open(server, :a, :low)
    assert :ok = ParakeetDiar.Server.open(server, :b, :low)
    assert {:error, :busy} = ParakeetDiar.Server.open(server, :c, :low)

    assert :ok = ParakeetDiar.Server.close(server, :a)
    assert :ok = ParakeetDiar.Server.open(server, :c, :low)
    assert {:error, :busy} = ParakeetDiar.Server.open(server, :d, :low)

    GenServer.stop(server)
  end

  test "the default cap is 8 streams" do
    server = start_server([])

    for tag <- 1..8 do
      assert :ok = ParakeetDiar.Server.open(server, tag, :ultra_low)
    end

    assert {:error, :busy} = ParakeetDiar.Server.open(server, 9, :ultra_low)
    GenServer.stop(server)
  end

  test "unknown tags, duplicate tags and bad latencies are errors, not crashes" do
    server = start_server([])

    assert {:error, :unknown_tag} = ParakeetDiar.Server.feed(server, :nobody, <<0, 0>>)
    assert {:error, :unknown_tag} = ParakeetDiar.Server.active(server, :nobody)
    assert {:error, :unknown_tag} = ParakeetDiar.Server.close(server, :nobody)

    assert :ok = ParakeetDiar.Server.open(server, :x, :low)
    assert {:error, :already_open} = ParakeetDiar.Server.open(server, :x, :low)
    assert {:error, :bad_latency} = ParakeetDiar.Server.open(server, :y, :bogus)

    assert Process.alive?(server)
    GenServer.stop(server)
  end

  test "stopping the server frees every stream and the model without crashing" do
    server = start_server(max_streams: 4)
    assert :ok = ParakeetDiar.Server.open(server, :one, :low)
    assert :ok = ParakeetDiar.Server.open(server, :two, :model)

    {:ok, _} =
      ParakeetDiar.Server.feed(server, :one, binary_part(ParakeetDiar.TestHelper.pcm(), 0, 3200))

    ref = Process.monitor(server)
    assert :ok = GenServer.stop(server, :normal)
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
  end

  test "a server with a bad model path stops at init" do
    Process.flag(:trap_exit, true)

    assert {:error, {:load_failed, _}} =
             ParakeetDiar.Server.start_link(model: "/nonexistent.gguf")
  end
end
