defmodule Rinhex.RawTcpServer do
  require Logger
  alias Rinhex.{LocalBuffer, WorkerController}

  @http_204_keepalive "HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n"
  @http_204_close "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
  @http_200_json_keepalive "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n"
  @http_200_json_close "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n"
  @max_requests_per_connection 10_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ []) do
    Task.start_link(fn ->
      init_persistent_responses()
      accept_loop(opts)
    end)
  end

  defp init_persistent_responses do
    :persistent_term.put(:http_204_keepalive, @http_204_keepalive)
    :persistent_term.put(:http_204_close, @http_204_close)
    :persistent_term.put(:http_200_json_keepalive, @http_200_json_keepalive)
    :persistent_term.put(:http_200_json_close, @http_200_json_close)
  end

  defp accept_loop(_opts) do
    socket_path = System.get_env("UDS_SOCKET", "/tmp/rinhex.sock")
    File.rm(socket_path)
    File.mkdir_p!(Path.dirname(socket_path))

    listen_opts = [
      :binary,
      {:ifaddr, {:local, socket_path}},
      {:packet, :raw},
      {:active, false},
      {:reuseaddr, true},
      {:nodelay, true},
      {:delay_send, false},
      {:sndbuf, 16384},
      {:recbuf, 16384},
      {:backlog, 1024},
      {:exit_on_close, false}
    ]

    {:ok, listen_socket} = :gen_tcp.listen(0, listen_opts)
    File.chmod!(socket_path, 0o666)
    Logger.info("Raw TCP Server listening on #{socket_path}")

    for _ <- 1..(System.schedulers_online() * 2) do
      spawn_link(fn -> acceptor(listen_socket) end)
    end

    :timer.sleep(:infinity)
  end

  defp acceptor(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_connection(socket)
        acceptor(listen_socket)

      _ ->
        acceptor(listen_socket)
    end
  end

  defp handle_connection(socket) do
    handle_connection_loop(socket, 0)
  end

  defp handle_connection_loop(socket, request_count) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} ->
        should_close = process_request(socket, data, request_count + 1)

        if should_close or request_count + 1 >= @max_requests_per_connection do
          :gen_tcp.close(socket)
        else
          handle_connection_loop(socket, request_count + 1)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp process_request(socket, <<"POST /payments", _::binary>> = data, _request_count) do
    should_close = should_close_connection?(data)

    case :binary.match(data, <<"\r\n\r\n">>) do
      {pos, 4} ->
        body_start = pos + 4
        body = :binary.part(data, body_start, byte_size(data) - body_start)

        if byte_size(body) > 0 do
          LocalBuffer.enqueue(body)
        end

      _ ->
        :ok
    end

    response =
      if should_close do
        :persistent_term.get(:http_204_close)
      else
        :persistent_term.get(:http_204_keepalive)
      end

    :gen_tcp.send(socket, response)
    should_close
  end

  defp process_request(socket, <<"GET /payments-summary", rest::binary>>, _request_count) do
    should_close = should_close_connection?(<<"GET /payments-summary", rest::binary>>)
    {from, to} = parse_query_params(rest)

    # Call worker for summary
    case :erpc.call(:rinhex@worker, WorkerController, :get_payments_summary, [from, to], 20_000) do
      {:badrpc, _} ->
        empty_summary =
          "{\"default\":{\"totalRequests\":0,\"totalAmount\":0.0},\"fallback\":{\"totalRequests\":0,\"totalAmount\":0.0}}"

        send_json_response(socket, empty_summary, should_close)

      summary_json when is_binary(summary_json) or is_list(summary_json) ->
        send_json_response(socket, summary_json, should_close)
    end

    should_close
  end

  defp process_request(socket, _data, __request_count) do
    :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
    true
  end

  defp send_json_response(socket, json_data, should_close) do
    content_length = IO.iodata_length(json_data)

    header =
      if should_close do
        :persistent_term.get(:http_200_json_close)
      else
        :persistent_term.get(:http_200_json_keepalive)
      end

    response = [
      header,
      "Content-Length: ",
      Integer.to_string(content_length),
      "\r\n\r\n",
      json_data
    ]

    :gen_tcp.send(socket, response)
  end

  defp parse_query_params(rest) do
    try do
      case rest do
        <<"?", query_rest::binary>> ->
          query =
            case :binary.match(query_rest, <<" HTTP/">>) do
              {pos, _} -> :binary.part(query_rest, 0, pos)
              :nomatch -> ""
            end

          from = extract_param(query, "from=")
          to = extract_param(query, "to=")
          {from, to}

        _ ->
          {nil, nil}
      end
    rescue
      _ -> {nil, nil}
    end
  end

  defp extract_param(query, param_prefix) do
    case :binary.match(query, param_prefix) do
      {start_pos, prefix_len} ->
        value_start = start_pos + prefix_len
        remaining = :binary.part(query, value_start, byte_size(query) - value_start)

        case :binary.match(remaining, <<"&">>) do
          {end_pos, _} ->
            value = :binary.part(remaining, 0, end_pos)
            URI.decode(value)

          :nomatch ->
            URI.decode(remaining)
        end

      :nomatch ->
        nil
    end
  end

  defp should_close_connection?(data) do
    case :binary.match(data, <<"Connection: close">>) do
      {_, _} -> true
      :nomatch -> false
    end
  end
end
