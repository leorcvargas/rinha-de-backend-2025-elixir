defmodule Rinhex.HttpServer do
  alias Rinhex.{LocalBuffer, WorkerController}

  @http_204 "HTTP/1.1 204 No Content\r\n\r\n"
  @http_200 "HTTP/1.1 200 OK\r\n"
  @http_200_json "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
  @http_404 "HTTP/1.1 404 Not Found\r\n\r\n"
  @pong_response @http_200 <> "Content-Length: 4\r\n\r\npong"

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(opts \\ []) do
    socket_path =
      System.get_env("UDS_SOCKET") ||
        Keyword.get(opts, :socket_path) ||
        "/tmp/rinha.sock"

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        start_server(socket_path)

        receive do
          {:EXIT, _from, reason} ->
            File.rm(socket_path)
            exit(reason)
        end
      end)

    {:ok, pid}
  end

  defp start_server(socket_path) do
    File.rm(socket_path)
    File.mkdir_p!(Path.dirname(socket_path))

    opts = [
      :binary,
      {:ifaddr, {:local, socket_path}},
      {:packet, :raw},
      {:active, false},
      {:backlog, 1024},
      {:exit_on_close, false}
    ]

    case :gen_tcp.listen(0, opts) do
      {:ok, listen_socket} ->
        File.chmod!(socket_path, 0o666)

        # 2 acceptors for 0.35 vCPU
        spawn_link(fn -> acceptor_loop(listen_socket) end)
        spawn_link(fn -> acceptor_loop(listen_socket) end)

        listen_socket

      {:error, reason} ->
        exit({:listen_failed, reason})
    end
  end

  defp acceptor_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_request(socket)
        acceptor_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        :timer.sleep(10)
        acceptor_loop(listen_socket)
    end
  end

  defp handle_request(socket) do
    # Read with same timeout as @req_len approach
    case :gen_tcp.recv(socket, 0, 500) do
      {:ok, data} ->
        response = route_request(data)
        :gen_tcp.send(socket, response)

      _ ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp route_request(<<"POST /payments HTTP/1.", _version::size(8), _rest::binary>> = request) do
    case extract_body(request) do
      {:ok, body} ->
        LocalBuffer.enqueue(body)

      _ ->
        :ok
    end

    @http_204
  end

  defp route_request(<<"GET /payments-summary", rest::binary>>) do
    {from, to} = parse_query_params(rest)

    summary_json =
      :erpc.call(
        :rinhex@worker,
        WorkerController,
        :get_payments_summary,
        [from, to],
        5_000
      )

    content_length = IO.iodata_length(summary_json)

    [
      @http_200_json,
      "Content-Length: ",
      Integer.to_string(content_length),
      "\r\n\r\n",
      summary_json
    ]
  end

  defp route_request(<<"GET /ping HTTP/1.", _::binary>>) do
    @pong_response
  end

  defp route_request(_) do
    @http_404
  end

  defp extract_body(request) do
    case :binary.split(request, <<"\r\n\r\n">>) do
      [_headers, body] when byte_size(body) > 0 ->
        {:ok, body}

      _ ->
        {:error, :no_body}
    end
  end

  defp parse_query_params(rest) do
    case rest do
      <<"?", query_rest::binary>> ->
        # Extract query string before HTTP version
        query =
          case :binary.split(query_rest, " HTTP/") do
            [q, _] -> q
            _ -> ""
          end

        # Parse from and to params
        params = parse_query_string(query)
        {params["from"], params["to"]}

      _ ->
        {nil, nil}
    end
  end

  defp parse_query_string(query_string) do
    query_string
    |> String.split("&")
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, URI.decode(value))
        _ -> acc
      end
    end)
  end
end
