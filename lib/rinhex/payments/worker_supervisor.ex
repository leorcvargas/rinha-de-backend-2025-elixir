defmodule Rinhex.Payments.WorkerSupervisor do
  use DynamicSupervisor

  def start_link(_) do
    sup = DynamicSupervisor.start_link(__MODULE__, :no_args, name: __MODULE__)
    Enum.each(1..get_num_workers(), &start_worker/1)

    sup
  end

  def init(:no_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_worker(_) do
    DynamicSupervisor.start_child(
      __MODULE__,
      Rinhex.Payments.Worker
    )
  end

  defp get_num_workers, do: 16
end
