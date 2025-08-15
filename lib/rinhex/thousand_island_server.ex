defmodule Rinhex.ThousandIslandServer do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    socket_path = System.get_env("UDS_SOCKET")

    File.rm(socket_path)
    File.mkdir_p!(Path.dirname(socket_path))

    children = [
      {
        ThousandIsland,
        port: 0,
        handler_module: Rinhex.ThousandIslandHandler,
        handler_options: %{},
        transport_module: ThousandIsland.Transports.TCP,
        transport_options: [
          ip: {:local, socket_path},
          backlog: 65535,
          nodelay: true,
          send_timeout: 5_000,
          send_timeout_close: true,
          sndbuf: 65536,
          recbuf: 65536
        ],
        num_acceptors: 10,
        num_connections: 100,
        max_connections_retry_count: 0,
        max_connections_retry_wait: 0,
        shutdown_timeout: 1_000,
        silent_terminate_on_error: true
      }
    ]

    spawn(fn ->
      :timer.sleep(100)
      File.chmod!(socket_path, 0o777)
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
