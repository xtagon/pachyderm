defmodule CounterTest do
  use ExUnit.Case
  doctest Counter

  # setup do
  #   {:ok, _} = Application.ensure_all_started(:inets)
  #   {:ok, pid} = Counter.WWW.start_link(%{}, port: 0)
  #   {:ok, port} = Ace.HTTP.Service.port(pid)
  #   IO.inspect(port)
  #   {:ok, %{port: port}}
  # end

  test "run through" do
    assert = {:ok, 1} = Pachyderm.activate({Counter, "a"}, :request)
    assert = {:ok, 2} = Pachyderm.activate({Counter, "a"}, :request)
    assert = {:ok, 1} = Pachyderm.activate({Counter, "b"}, :request)
  end

  @tag :skip
  test "counts the state of previous requests" do
    Raxx.request(:GET, "/_/123/")
    |> send_sync("https://www.google.com")
    |> IO.inspect()
  end

  def send_sync(request, host) do
    httpc_method =
      case request.method do
        :GET ->
          :get
      end

    httpc_request =
      case request.body do
        b when b in ["", false] ->
          IO.inspect(host)
          IO.inspect(request.raw_path)
          {url(host, request), request.headers}
      end
      |> IO.inspect()

    IO.inspect(httpc_method)
    :httpc.request(httpc_method, httpc_request, [], [])
  end

  defp url(host, %{raw_path: raw_path}) do
    :erlang.binary_to_list(
      case raw_path do
        "/" ->
          host

        _ ->
          Path.join(host, raw_path)
      end
    )
  end
end
