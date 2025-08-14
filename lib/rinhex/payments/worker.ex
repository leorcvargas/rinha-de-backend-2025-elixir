defmodule Rinhex.Payments.Worker do
  use GenServer
  require Logger

  alias Rinhex.Payments.{ProcessorClient, Queue}
  alias Rinhex.{Semaphore, Storage}

  @event_tick :tick
  @tick_ms 0
  @delay_tick_ms 0

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state)
  end

  @impl true
  def init(state) do
    schedule_tick()

    {:ok, state}
  end

  @impl true
  def handle_info(@event_tick, state) do
    Queue.take()
    |> process()
    |> next_tick_time_by_result()
    |> schedule_tick()

    {:noreply, state}
  end

  defp process(nil), do: :retry

  defp process({correlation_id, amount}) do
    get_best_payment_processor()
    |> call_payment_processor({correlation_id, amount})
    |> handle_result()
  end

  defp get_best_payment_processor() do
    Semaphore.get_best_service()
  end

  defp call_payment_processor(:none, input), do: {:retry, :no_service, input}

  defp call_payment_processor(service, {correlation_id, amount}) do
    input = {
      correlation_id,
      amount,
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()
    }

    service
    |> ProcessorClient.create_payment(input)
    |> case do
      {:ok, payment} ->
        {:done, payment}

      {:error, :unprocessable} ->
        {:skip, {correlation_id, amount}}

      {:error, _} ->
        {:retry, :service_error, {correlation_id, amount, service}}
    end
  end

  defp handle_result({:done, payment}) do
    Storage.Writer.self_insert_payment(payment)
    :done
  end

  defp handle_result({:retry, :no_service, {correlation_id, amount}}) do
    Queue.self_put({correlation_id, amount})
    :retry
  end

  defp handle_result({:retry, :service_error, {correlation_id, amount, service}}) do
    IO.puts("service error")
    Semaphore.report_error(service)
    Queue.self_put({correlation_id, amount})
    :retry
  end

  defp handle_result({:skip, _input}), do: :skip

  defp schedule_tick(time \\ @tick_ms) do
    Process.send_after(self(), @event_tick, time)
  end

  defp next_tick_time_by_result(:done), do: @tick_ms

  defp next_tick_time_by_result(:retry), do: @delay_tick_ms
end
