defmodule Rinhex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  alias Rinhex.WorkerController
  require Logger
  use Application

  @impl true
  def start(_type, _args) do
    topologies = [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: []
      ]
    ]

    socket_path =
      if socket_path_env = System.get_env("UDS_SOCKET") do
        dir = Path.dirname(socket_path_env)
        File.mkdir_p!(dir)
        :ok = :file.change_mode(dir, 0o777)
        File.rm_rf(socket_path_env)
        socket_path_env
      else
        nil
      end

    application_mode = System.get_env("APPLICATION_MODE")

    children =
      case application_mode do
        "api" ->
          [
            {
              Cluster.Supervisor,
              [
                topologies,
                [name: Rinhex.ClusterSupervisor]
              ]
            },
            Rinhex.LocalBuffer,
            {
              Bandit,
              plug: RinhexWeb.HttpServer, scheme: :http, ip: {:local, socket_path}, port: 0
              # http_1_options: [
              # clear_process_dict: false
              # gc_every_n_keepalive_requests: 2
              # gc_every_n_keepalive_requests: 20_000
              # ],
              # thousand_island_options: [
              #   num_acceptors: 5,
              #   num_connections: 1024 * 8
              # ]
            },
            {Task, fn -> wait_and_chmod!(socket_path, 0o777) end}
          ]

        "worker" ->
          [
            {
              Cluster.Supervisor,
              [
                topologies,
                [name: Rinhex.ClusterSupervisor]
              ]
            },
            {
              Finch,
              name: Rinhex.Finch,
              pools: %{
                :default => [
                  size: 125,
                  count: 1
                ]
              }
            },
            Rinhex.Payments.Queue,
            Rinhex.Payments.WorkerSupervisor,
            {Rinhex.Semaphore, %{service: :default}},
            Rinhex.SemaphoreWorker,
            Rinhex.Storage.Master,
            Rinhex.Storage.Writer,
            Rinhex.Storage.Reader,
            Rinhex.WorkerController
          ]
      end

    opts = [strategy: :one_for_one, name: Rinhex.Supervisor]

    Supervisor.start_link(children, opts)
  end

  @impl true
  def prep_stop(_) do
    task =
      Task.async(fn ->
        final_summary =
          System.get_env("APPLICATION_MODE")
          |> case do
            "api" ->
              :erpc.call(
                :rinhex@worker,
                WorkerController,
                :get_payments_summary,
                [nil, nil],
                5_000
              )

            "worker" ->
              WorkerController.get_payments_summary(nil, nil)
          end

        Logger.info("Final summary pre sleep: #{final_summary}")

        Process.sleep(1_500)

        final_summary =
          System.get_env("APPLICATION_MODE")
          |> case do
            "api" ->
              :erpc.call(
                :rinhex@worker,
                WorkerController,
                :get_payments_summary,
                [nil, nil],
                5_000
              )

            "worker" ->
              WorkerController.get_payments_summary(nil, nil)
          end

        Logger.info("Final summary post sleep: #{final_summary}")
      end)

    Task.await(task)
  end

  def wait_and_chmod!(path, mode, tries \\ 100, sleep_ms \\ 10) do
    wait_path(path, tries, sleep_ms)
    :ok = :file.change_mode(path, mode)
    :ok
  end

  defp wait_path(_path, 0, _), do: :ok

  defp wait_path(path, n, sleep_ms) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(sleep_ms)
          wait_path(path, n - 1, sleep_ms)
        )
  end
end
