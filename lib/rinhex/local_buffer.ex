defmodule Rinhex.LocalBuffer do
  use GenServer
  alias Rinhex.WorkerController

  @table :payment_buffer

  @min_flush_interval 1
  @max_flush_interval 50
  @growth_factor 1.5
  @shrink_threshold 10
  @dummy_key 0

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(_state) do
    Process.flag(:min_heap_size, 2048)
    Process.flag(:min_bin_vheap_size, 4096)

    :ets.new(@table, [
      :named_table,
      :public,
      :duplicate_bag,
      {:write_concurrency, true}
    ])

    Process.send_after(self(), :flush, @min_flush_interval)
    {:ok, %{current_interval: @min_flush_interval}}
  end

  @compile {:inline, enqueue: 1}
  def enqueue(raw_body) do
    :ets.insert(@table, {@dummy_key, raw_body})

    :ok
  end

  def handle_info(:flush, %{current_interval: current_interval} = state) do
    item_count = flush_buffer()
    next_interval = calculate_next_interval(item_count, current_interval)

    Process.send_after(self(), :flush, next_interval)
    {:noreply, %{state | current_interval: next_interval}}
  end

  defp flush_buffer do
    case :ets.take(@table, @dummy_key) do
      [] ->
        0

      records ->
        records
        |> Enum.map(&elem(&1, 1))
        |> WorkerController.batch_enqueue_payments()

        length(records)
    end
  end

  defp calculate_next_interval(item_count, current_interval) do
    cond do
      item_count >= @shrink_threshold ->
        @min_flush_interval

      item_count == 0 ->
        min(
          trunc(current_interval * @growth_factor),
          @max_flush_interval
        )

      true ->
        min(
          trunc(current_interval * 1.1),
          @max_flush_interval
        )
    end
  end
end
