defmodule Rinhex.LocalBuffer do
  use GenServer
  require Logger

  alias Rinhex.WorkerController

  @table :payment_buffer
  @flush_interval 50
  @dummy_key 0

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [
      :named_table,
      :public,
      :duplicate_bag,
      {:write_concurrency, true}
    ])

    Process.send_after(self(), :flush, @flush_interval)
    {:ok, %{counter: 0}}
  end

  @compile {:inline, enqueue: 1}
  def enqueue(raw_body) do
    :ets.insert(@table, {@dummy_key, raw_body})
    GenServer.cast(__MODULE__, :increment_counter)
    :ok
  end

  def handle_cast(:increment_counter, state) do
    counter = state.counter + 1

    Logger.info("Total items seen: #{counter}")

    {:noreply, %{state | counter: counter}}
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

  def handle_call(:get_counter, _from, state) do
    {:reply, state.counter, state}
  end

  def get_counter do
    GenServer.call(__MODULE__, :get_counter)
  end
end
