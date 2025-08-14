defmodule Rinhex.HttpServer do
  @moduledoc """
  Ultra-minimal UDS server with keep-alive support for Rinha 2025.
  Optimized for 0.35 vCPU constraint.
  """

  alias Rinhex.{LocalBuffer, WorkerController}

  @http_204 "HTTP/1.1 204 No Content\r\n\r\n"
  @http_200 "HTTP/1.1 200 OK\r\n"
  @http_200_json "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
  @http_404 "HTTP/1.1 404 Not Found\r\n\r\n"

  @pong_response @http_200 <> "Content-Length: 4\r\n\r\npong"

  @max_keepalive_requests 100
  @keepalive_timeout 25_000

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
        Keyword.get(opts, :socket_path)

    if !socket_path do
      raise "Environment variable UDS_SOCKET is missing"
    end

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

        # TODO: control number of acceptors in options
        Enum.each(1..2, fn _ ->
          spawn_link(fn -> acceptor_loop(listen_socket) end)
        end)

        listen_socket

      {:error, reason} ->
        exit({:listen_failed, reason})
    end
  end

  defp acceptor_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket, 0) end)
        acceptor_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        # :timer.sleep(10)
        acceptor_loop(listen_socket)
    end
  end

  defp handle_connection(socket, request_count) when request_count >= @max_keepalive_requests do
    :gen_tcp.close(socket)
  end

  defp handle_connection(socket, request_count) do
    case :gen_tcp.recv(socket, 0, @keepalive_timeout) do
      {:ok, data} ->
        response = route_request(data)
        :gen_tcp.send(socket, response)

        if should_keep_alive?(data) do
          handle_connection(socket, request_count + 1)
        else
          :gen_tcp.close(socket)
        end

      {:error, :timeout} ->
        :gen_tcp.close(socket)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp should_keep_alive?(request) do
    cond do
      String.contains?(request, " HTTP/1.0") ->
        String.contains?(request, "Connection: keep-alive")

      String.contains?(request, " HTTP/1.1") ->
        not String.contains?(request, "Connection: close")

      true ->
        false
    end
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
        query =
          case :binary.split(query_rest, " HTTP/") do
            [q, _] -> q
            _ -> ""
          end

        params =
          query
          |> String.split("&")
          |> Enum.reduce(%{}, fn pair, acc ->
            case String.split(pair, "=", parts: 2) do
              [key, value] -> Map.put(acc, key, URI.decode(value))
              _ -> acc
            end
          end)

        {params["from"], params["to"]}

      _ ->
        {nil, nil}
    end
  end
end
