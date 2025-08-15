defmodule Rinhex.Storage.Master do
  use GenServer

  @table :rinhex_boring_storage

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    table =
      :ets.new(@table, [
        :named_table,
        :ordered_set,
        :public,
        read_concurrency: :auto,
        write_concurrency: :auto
      ])

    {:ok, table}
  end
end
