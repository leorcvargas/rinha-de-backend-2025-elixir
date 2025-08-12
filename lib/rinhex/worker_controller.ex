defmodule Rinhex.WorkerController do
  use GenServer
  alias Rinhex.WorkerController
  alias Rinhex.Storage
  alias Rinhex.Payments.Queue

  @dest {WorkerController, :rinhex@worker}
  @payment_body_attrs %{correlation_id: :correlationId, amount: :amount}

  def start_link(state) do
    GenServer.start_link(__MODULE__, state, name: WorkerController)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_info({:enqueue_payment, raw_body}, state) do
    parse_and_enqueue(raw_body)

    {:noreply, state}
  end

  def handle_info({:batch_enqueue_payments, raw_bodies}, state) do
    Enum.each(raw_bodies, &parse_and_enqueue/1)

    {:noreply, state}
  end

  def enqueue_payment(raw_body) do
    Process.send(
      @dest,
      {:enqueue_payment, raw_body},
      [:noconnect, :nosuspend]
    )
  end

  def batch_enqueue_payments(raw_bodies) do
    Process.send(
      @dest,
      {:batch_enqueue_payments, raw_bodies},
      [:noconnect, :nosuspend]
    )
  end

  def get_payments_summary(from, to) do
    summary = Storage.Reader.get_payments_summary(from, to)

    [
      "{\"default\":{\"totalRequests\":",
      Integer.to_string(summary.default.total_requests),
      ",\"totalAmount\":",
      :erlang.float_to_binary(summary.default.total_amount, [:short]),
      "},\"fallback\":{\"totalRequests\":",
      Integer.to_string(summary.fallback.total_requests),
      ",\"totalAmount\":",
      :erlang.float_to_binary(summary.fallback.total_amount, [:short]),
      "}}"
    ]
  end

  defp parse_and_enqueue(raw_body) do
    raw_body
    |> Jason.decode(keys: :atoms!)
    |> case do
      {:ok, body} ->
        correlation_id = Map.get(body, @payment_body_attrs.correlation_id)
        amount = Map.get(body, @payment_body_attrs.amount)

        Queue.self_put({
          correlation_id,
          amount
        })

      {:error, reason} ->
        {:error, reason}
    end
  end
end
