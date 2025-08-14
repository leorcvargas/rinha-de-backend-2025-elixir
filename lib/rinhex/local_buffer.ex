defmodule Rinhex.LocalBuffer do
  use GenServer
  alias Rinhex.WorkerController

  @table :payment_buffer

  @flush_interval 5
  @dummy_key 0

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(_state) do
    :ets.new(@table, [
      :named_table,
      :public,
      :duplicate_bag,
      {:write_concurrency, true}
    ])

    Process.send_after(self(), :flush, @flush_interval)
    {:ok, %{}}
  end

  @compile {:inline, enqueue: 1}
  def enqueue(raw_body) do
    :ets.insert(@table, {@dummy_key, raw_body})
    :ok
  end

  def handle_info(:flush, state) do
    case :ets.take(@table, @dummy_key) do
      [] ->
        :ok

      records ->
        records
        |> Enum.map(&elem(&1, 1))
        |> WorkerController.batch_enqueue_payments()
    end

    Process.send_after(self(), :flush, @flush_interval)

    {:noreply, state}
  end
end
