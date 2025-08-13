defmodule Rinhex.Storage.Reader do
  use GenServer

  @table :rinhex_boring_storage
  @empty_summary %{
    default: %{total_requests: 0, total_amount: 0.0},
    fallback: %{total_requests: 0, total_amount: 0.0}
  }

  def start_link(state \\ []) do
    GenServer.start_link(__MODULE__, state, name: build_name(node()))
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call({:cross_node_query, {from, to}}, _from, state),
    do:
      from
      |> query_by_date(to)
      |> then(fn data -> {:reply, data, state} end)

  def get_payments_summary(from, to) do
    local_summary =
      query_by_date(from, to)
      |> aggregate_summary()

    # other_summaries =
    #   Node.list(:visible)
    #   |> Enum.map(fn node ->
    #     node
    #     |> build_name()
    #     |> GenServer.call({:cross_node_query, {from, to}})
    #     |> aggregate_summary()
    #   end)

    all_summaries = [local_summary]
    # ++ other_summaries

    all_summaries
    |> Enum.reduce(
      @empty_summary,
      fn global_summary, summary ->
        summary
        |> update_in(
          [:default, :total_requests],
          &(&1 + global_summary.default.total_requests)
        )
        |> update_in([:default, :total_amount], &(&1 + global_summary.default.total_amount))
        |> update_in(
          [:fallback, :total_requests],
          &(&1 + global_summary.fallback.total_requests)
        )
        |> update_in([:fallback, :total_amount], &(&1 + global_summary.fallback.total_amount))
      end
    )
  end

  def aggregate_summary(payments) do
    payments
    |> Enum.reduce(
      @empty_summary,
      fn {amount, service}, summary ->
        summary
        |> update_in([service, :total_requests], &(&1 + 1))
        |> update_in([service, :total_amount], &(&1 + amount))
      end
    )
    |> update_in([:default, :total_amount], &Float.round(&1, 2))
    |> update_in([:fallback, :total_amount], &Float.round(&1, 2))
  end

  def query_by_date(from, to) do
    head =
      {
        :_,
        :"$2",
        :"$3",
        :"$4"
        # correlation_id :_
      }

    result_fields = [{{:"$3", :"$4"}}]

    ms =
      case {from, to} do
        {nil, nil} ->
          [
            {
              head,
              [],
              result_fields
            }
          ]

        {from_iso, nil} ->
          [
            {
              head,
              [{:>=, :"$2", from_iso}],
              result_fields
            }
          ]

        {nil, to_iso} ->
          [
            {
              head,
              [{:"=<", :"$2", to_iso}],
              result_fields
            }
          ]

        {from_iso, to_iso} ->
          [
            {
              head,
              [
                {:>=, :"$2", from_iso},
                {:"=<", :"$2", to_iso}
              ],
              result_fields
            }
          ]
      end

    :ets.select(@table, ms)
  end

  def build_name(node) do
    {:global, :"#{node}_boring_storage_reader"}
  end
end
