defmodule Rinhex.Payments.ProcessorClient do
  alias Req
  require Logger

  @headers [{"Content-Type", "application/json"}]
  @post_endpoint "/payments"
  @health_endpoint "/payments/service-health"
  @payment_json_slice_1 "{\"correlationId\":\""
  @payment_json_slice_2 "\",\"amount\":"
  @payment_json_slice_3 ",\"requestedAt\":\""
  @payment_json_slice_4 "\"}"
  @field_failing "failing"
  @field_min_response_time "failing"

  def create_payment(
        service,
        {correlation_id, amount, requested_at}
      ) do
    request_url = "#{url(service)}#{@post_endpoint}"

    finch_request =
      :post
      |> Finch.build(
        request_url,
        @headers,
        payment_to_json_iodata({correlation_id, amount, requested_at})
      )

    result = finch_request |> Finch.request(Rinhex.Finch)

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, {correlation_id, amount, requested_at, service}}

      {:ok, %{status: status}} when status == 422 ->
        {:error, :unprocessable}

      _ ->
        {:error, :unexpected}
    end
  end

  def get_service_health(service) do
    request_url = "#{url(service)}#{@health_endpoint}"

    :get
    |> Finch.build(
      request_url,
      @headers
    )
    |> Finch.request(Rinhex.Finch, receive_timeout: 10_000)
    |> case do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        body
        |> JSON.decode()
        |> case do
          {:ok, decoded_body} ->
            %{
              service: service,
              failing: decoded_body[@field_failing],
              min_response_time: decoded_body[@field_min_response_time]
            }

          _ ->
            %{
              service: service,
              failing: true,
              min_response_time: :infinity
            }
        end

      _ ->
        %{
          service: service,
          failing: true,
          min_response_time: :infinity
        }
    end
  end

  defp url(:default), do: default_url()

  defp url(:fallback), do: fallback_url()

  defp default_url, do: Application.get_env(:rinhex, :processor_default_url)

  defp fallback_url, do: Application.get_env(:rinhex, :processor_fallback_url)

  defp payment_to_json_iodata({correlation_id, amount, requested_at}),
    do: [
      @payment_json_slice_1,
      correlation_id,
      @payment_json_slice_2,
      :erlang.float_to_binary(amount),
      @payment_json_slice_3,
      requested_at,
      @payment_json_slice_4
    ]
end
