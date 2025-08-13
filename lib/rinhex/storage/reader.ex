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

  def get_payments_summary(from, to) do
    from = iso_to_unix(from)
    to = iso_to_unix(to)

    query_by_date(from, to)
    |> aggregate_summary()
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

  defp iso_to_unix(nil), do: nil

  defp iso_to_unix(iso_dt) do
    iso_dt
    |> DateTime.from_iso8601()
    |> then(fn {:ok, dt, 0} -> dt end)
    |> DateTime.to_unix(:millisecond)
  end
end
