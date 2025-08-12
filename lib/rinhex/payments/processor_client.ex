defmodule Rinhex.Payments.ProcessorClient do
  alias Req
  require Logger

  def create_payment(
        service,
        {correlation_id, amount, requested_at}
      ) do
    request_url = "#{url(service)}/payments"

    finch_request =
      :post
      |> Finch.build(
        request_url,
        [{"Content-Type", "application/json"}],
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
    request_url = "#{url(service)}/payments/service-health"

    :get
    |> Finch.build(
      request_url,
      [{"Content-Type", "application/json"}]
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
              failing: decoded_body["failing"],
              min_response_time: decoded_body["minResponseTime"]
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
      "{\"correlationId\":\"",
      correlation_id,
      "\",\"amount\":",
      :erlang.float_to_binary(amount),
      ",\"requestedAt\":\"",
      requested_at,
      "\"}"
    ]
end
