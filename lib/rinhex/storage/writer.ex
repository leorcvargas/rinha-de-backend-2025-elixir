defmodule Rinhex.Storage.Writer do
  use GenServer
  require Logger

  @table :rinhex_boring_storage
  @event_insert_payment :insert_payment

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({@event_insert_payment, {correlation_id, amount, requested_at, service}}, state) do
    key = make_key()

    :ets.insert(
      @table,
      {
        key,
        requested_at,
        amount,
        service,
        correlation_id
      }
    )

    {:noreply, state}
  end

  def insert_payment(payment),
    do: GenServer.cast(__MODULE__, {@event_insert_payment, payment})

  defp make_key() do
    System.unique_integer([:monotonic, :positive])
  end
end
