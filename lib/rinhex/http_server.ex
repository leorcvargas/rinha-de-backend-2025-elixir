defmodule RinhexWeb.HttpServer do
  import Plug.Conn

  alias Rinhex.{LocalBuffer, WorkerController}

  @req_len 512

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: ["payments"]} = conn, _opts) do
    {:ok, raw_body, conn} =
      read_body(
        conn,
        length: @req_len,
        read_length: @req_len
      )

    LocalBuffer.enqueue(raw_body)
    # WorkerController.enqueue_payment(raw_body)
    # :erpc.cast(
    #   :rinhex@worker,
    #   WorkerController,
    #   :enqueue_payment,
    #   [raw_body]
    # )

    send_resp(conn, 204, "")
  end

  def call(%Plug.Conn{method: "GET", path_info: ["payments-summary"]} = conn, _opts) do
    conn = fetch_query_params(conn)

    from = conn.params["from"]
    to = conn.params["to"]

    summary_json =
      :erpc.call(:rinhex@worker, WorkerController, :get_payments_summary, [from, to], 5_000)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, summary_json)
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ping"]} = conn, _opts),
    do: send_resp(conn, 200, "pong")

  def call(conn, _opts), do: send_resp(conn, 404, "")
end
