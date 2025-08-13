defmodule Rinhex.Payments.Queue do
  require Logger
  use GenServer

  @table :rinhex_payments_queue

  def start_link(state \\ {}) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    :ets.new(@table, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(__MODULE__, :debug_size, 100)

    {:ok, state}
  end

  def handle_cast({:put, {correlation_id, amount}}, state) do
    :ets.insert(@table, {correlation_id, amount})

    {:noreply, state}
  end

  def handle_info(:debug_size, state) do
    Logger.info("Queue size: #{size()}")

    Process.send_after(__MODULE__, :debug_size, 100)

    {:noreply, state}
  end

  def put({correlation_id, amount}) do
    GenServer.cast(__MODULE__, {:put, {correlation_id, amount}})
  end

  def self_put({correlation_id, amount}) do
    :ets.insert(@table, {correlation_id, amount})
  end

  def take() do
    case :ets.first(@table) do
      :"$end_of_table" ->
        nil

      key ->
        case :ets.take(@table, key) do
          [{^key, value}] -> {key, value}
          [] -> take()
        end
    end
  end

  def size() do
    :ets.info(@table, :size)
  end
end
