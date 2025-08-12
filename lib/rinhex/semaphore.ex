defmodule Rinhex.Semaphore do
  require Logger
  alias Rinhex.SemaphoreWorker
  use GenServer

  @event_check_services :check_services
  @event_get_best_service :get_best_service
  @event_set_best_service :set_best_service
  @event_status :status
  @event_report_error :report_error
  @internal_in_ms 5000

  def start_link(state \\ %{service: :default}) when is_map(state) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    schedule_next_check()
    {:ok, state}
  end

  # NOTE: I can always return :default here and never lag a payment,
  # but I think this is kinda lame
  def get_best_service(), do: :default
  # def get_best_service(), do: GenServer.call(__MODULE__, @event_get_best_service)

  def set_best_service(best_service),
    do: GenServer.cast(__MODULE__, {@event_set_best_service, best_service})

  def report_error(service), do: GenServer.cast(__MODULE__, {@event_report_error, service})

  def handle_info(@event_check_services, state) do
    if acquire_turn() do
      try do
        SemaphoreWorker.work()
      after
        release_turn()
      end
    end

    schedule_next_check()

    {:noreply, state}
  end

  def handle_cast({@event_report_error, service}, state) do
    Logger.warning("Error on #{service} payment processor")

    state =
      case service do
        :default ->
          Map.put(state, :service, :fallback)

        :fallback ->
          Map.put(state, :service, :default)
      end

    {:noreply, state}
  end

  def handle_cast({@event_set_best_service, nil}, state) do
    {:noreply, state}
  end

  def handle_cast({@event_set_best_service, best_service}, state) do
    {:noreply, state |> Map.put(:service, best_service)}
  end

  def handle_call(@event_get_best_service, _from, state) do
    {:reply, state.service, state}
  end

  def handle_call(@event_status, _from, state) do
    {:reply, state, state}
  end

  defp acquire_turn do
    :global.set_lock({:rinhex, :semaphore_turn}, [Node.self()], 0)
  end

  defp release_turn do
    :global.del_lock({:rinhex, :semaphore_turn}, [Node.self()])
  end

  defp schedule_next_check() do
    Process.send_after(self(), @event_check_services, @internal_in_ms)
  end
end
