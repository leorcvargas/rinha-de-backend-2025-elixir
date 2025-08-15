defmodule Rinhex.ThousandIslandHandler do
  use ThousandIsland.Handler
  alias Rinhex.{LocalBuffer, WorkerController}

  @post_payments_pattern "POST /payments HTTP/1."
  @get_summary_pattern "GET /payments-summary"
  @get_ping_pattern "GET /ping HTTP/1."
  @body_separator "\r\n\r\n"
  @http_separator " HTTP/"
  @query_separator "?"
  @param_separator "&"
  @value_separator "="
  @http_204_keepalive "HTTP/1.1 204 No Content\r\nConnection: keep-alive\r\n\r\n"
  @http_204_close "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
  @http_200_json_keepalive "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n"
  @http_200_json_close "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n"
  @http_200_keepalive "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 4\r\n\r\npong"
  @http_200_close "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\npong"
  @http_404 "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"

  @recv_timeout 30_000
  @max_requests_per_connection 20_000

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    Process.flag(:min_heap_size, 2048)
    Process.flag(:min_bin_vheap_size, 4096)

    handle_requests(socket, state, 0)
  end

  defp handle_requests(_socket, state, count) when count >= @max_requests_per_connection do
    {:close, state}
  end

  defp handle_requests(socket, state, count) do
    case ThousandIsland.Socket.recv(socket, 0, @recv_timeout) do
      {:ok, data} ->
        keep_alive = count < @max_requests_per_connection - 1
        response = do_route_request(data, keep_alive)

        case ThousandIsland.Socket.send(socket, response) do
          :ok ->
            if keep_alive do
              handle_requests(socket, state, count + 1)
            else
              {:close, state}
            end

          {:error, _} ->
            {:close, state}
        end

      {:error, :timeout} ->
        {:close, state}

      {:error, _} ->
        {:close, state}
    end
  end

  defp do_route_request(request, keep_alive) do
    case request do
      <<@post_payments_pattern, _::binary>> ->
        case extract_body(request) do
          {:ok, body} ->
            LocalBuffer.enqueue(body)

          _ ->
            :ok
        end

        if keep_alive, do: @http_204_keepalive, else: @http_204_close

      <<@get_summary_pattern, rest::binary>> ->
        {from, to} = parse_query_params(rest)

        case :erpc.call(
               :rinhex@worker,
               WorkerController,
               :get_payments_summary,
               [from, to],
               20_000
             ) do
          {:badrpc, _} ->
            empty_summary =
              Jason.encode!(%{
                "default" => %{"totalRequests" => 0, "totalAmount" => 0.0},
                "fallback" => %{"totalRequests" => 0, "totalAmount" => 0.0}
              })

            build_json_response(empty_summary, keep_alive)

          summary_json when is_binary(summary_json) or is_list(summary_json) ->
            build_json_response(summary_json, keep_alive)
        end

      <<@get_ping_pattern, _::binary>> ->
        if keep_alive, do: @http_200_keepalive, else: @http_200_close

      _ ->
        @http_404
    end
  end

  defp build_json_response(json_data, keep_alive) do
    content_length = IO.iodata_length(json_data)
    header = if keep_alive, do: @http_200_json_keepalive, else: @http_200_json_close
    [header, "Content-Length: ", Integer.to_string(content_length), @body_separator, json_data]
  end

  @compile {:inline, extract_body: 1}
  defp extract_body(request) do
    case :binary.split(request, @body_separator, [:global]) do
      [_headers, body | _] when byte_size(body) > 0 ->
        {:ok, body}

      _ ->
        {:error, :no_body}
    end
  end

  defp parse_query_params(rest) do
    try do
      case rest do
        <<@query_separator, query_rest::binary>> ->
          query =
            case :binary.split(query_rest, @http_separator) do
              [q, _] -> q
              _ -> ""
            end

          params =
            query
            |> String.split(@param_separator)
            |> Enum.reduce(%{}, fn pair, acc ->
              case String.split(pair, @value_separator, parts: 2) do
                [key, value] -> Map.put(acc, key, URI.decode(value))
                _ -> acc
              end
            end)

          {params["from"], params["to"]}

        _ ->
          {nil, nil}
      end
    rescue
      _ -> {nil, nil}
    end
  end
end
