defmodule Rinhex.SemaphoreWorker do
  use GenServer

  alias Rinhex.Semaphore
  alias Rinhex.Payments.ProcessorClient

  @event_work :work

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast(@event_work, state) do
    [default_status, fallback_status] =
      Task.await_many(
        [
          Task.async(fn -> ProcessorClient.get_service_health(:default) end),
          Task.async(fn -> ProcessorClient.get_service_health(:fallback) end)
        ],
        15_000
      )

    best_service = define_service_by_statuses(default_status, fallback_status)

    Node.list([:this, :visible])
    |> :erpc.multicall(Semaphore, :set_best_service, [best_service], :infinity)

    {:noreply, state}
  end

  def work(), do: GenServer.cast(__MODULE__, @event_work)

  def define_service_by_statuses(
        %{service: :default, failing: true},
        %{service: :fallback, failing: true}
      ),
      do: :none

  def define_service_by_statuses(
        %{service: :default, failing: false, min_response_time: default_latency},
        %{service: :fallback, failing: false, min_response_time: fallback_latency}
      ) do
    cond do
      default_latency > fallback_latency ->
        :fallback

      default_latency < fallback_latency ->
        :default

      true ->
        :default
    end
  end

  def define_service_by_statuses(
        %{service: :default, failing: true},
        %{service: :fallback, failing: false}
      ),
      do: :fallback

  def define_service_by_statuses(
        %{service: :default, failing: false},
        %{service: :fallback, failing: true}
      ),
      do: :default
end
