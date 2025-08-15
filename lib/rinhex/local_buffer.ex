defmodule Rinhex.LocalBuffer do
  use GenServer
  alias Rinhex.WorkerController

  @table :payment_buffer

  @flush_interval 2

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(_state) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    Process.send_after(self(), :flush, @flush_interval)
    {:ok, %{}}
  end

  @compile {:inline, enqueue: 1}
  def enqueue(raw_body) do
    key = :erlang.unique_integer([:monotonic])
    :ets.insert(@table, {key, raw_body})

    if :ets.info(@table, :size) > 50 do
      GenServer.cast(__MODULE__, :force_flush)
    end

    :ok
  end

  def handle_info(:flush, state) do
    flush_buffer()
    Process.send_after(self(), :flush, @flush_interval)
    {:noreply, state}
  end

  def handle_cast(:force_flush, state) do
    flush_buffer()
    {:noreply, state}
  end

  defp flush_buffer do
    records = :ets.tab2list(@table)

    case records do
      [] ->
        :ok

      _ ->
        :ets.delete_all_objects(@table)

        records
        |> Enum.map(&elem(&1, 1))
        |> WorkerController.batch_enqueue_payments()
    end
  end
end
