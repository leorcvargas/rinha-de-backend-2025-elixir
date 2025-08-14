defmodule Rinhex.ThousandIslandHandler do
  use ThousandIsland.Handler

  alias Rinhex.{LocalBuffer, WorkerController}

  @http_204 "HTTP/1.1 204 No Content\r\n\r\n"
  @http_200_json "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
  @http_200 "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong"
  @http_404 "HTTP/1.1 404 Not Found\r\n\r\n"
  @http_503 "HTTP/1.1 503 Service Unavailable\r\n\r\n"

  @recv_timeout 500
  @max_requests_per_connection 10

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    handle_requests(socket, state, 0)
  end

  defp handle_requests(_socket, state, count) when count >= @max_requests_per_connection do
    {:close, state}
  end

  defp handle_requests(socket, state, count) do
    case ThousandIsland.Socket.recv(socket, 0, @recv_timeout) do
      {:ok, data} ->
        response = route_request(data)

        case ThousandIsland.Socket.send(socket, response) do
          :ok ->
            if should_keep_alive?(data) and count < @max_requests_per_connection - 1 do
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

  defp route_request(data) do
    try do
      do_route_request(data)
    rescue
      _ -> @http_503
    end
  end

  defp do_route_request(<<"POST /payments HTTP/1.", _::binary>> = request) do
    case extract_body(request) do
      {:ok, body} ->
        LocalBuffer.enqueue(body)

      _ ->
        :ok
    end

    @http_204
  end

  defp do_route_request(<<"GET /payments-summary", rest::binary>>) do
    {from, to} = parse_query_params(rest)

    case :erpc.call(:rinhex@worker, WorkerController, :get_payments_summary, [from, to], 1_000) do
      {:badrpc, _} ->
        # Worker is down, return empty summary
        empty_summary =
          Jason.encode!(%{
            "default" => %{"totalRequests" => 0, "totalAmount" => 0.0},
            "fallback" => %{"totalRequests" => 0, "totalAmount" => 0.0}
          })

        build_json_response(empty_summary)

      summary_json when is_binary(summary_json) or is_list(summary_json) ->
        build_json_response(summary_json)
    end
  end

  defp do_route_request(<<"GET /ping HTTP/1.", _::binary>>) do
    @http_200
  end

  defp do_route_request(_) do
    @http_404
  end

  defp build_json_response(json_data) do
    content_length = IO.iodata_length(json_data)
    [@http_200_json, "Content-Length: ", Integer.to_string(content_length), "\r\n\r\n", json_data]
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
    try do
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
    rescue
      _ -> {nil, nil}
    end
  end
end
