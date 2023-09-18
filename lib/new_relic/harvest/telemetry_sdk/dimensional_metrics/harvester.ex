defmodule NewRelic.Harvest.TelemetrySdk.DimensionalMetrics.Harvester do
  use GenServer

  @moduledoc false

  alias NewRelic.Harvest
  alias NewRelic.Harvest.TelemetrySdk

  @interval_ms TelemetrySdk.Config.lookup(:dimensional_metrics_harvest_cycle)

  @valid_types [:count, :gauge, :summary]

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    {:ok,
     %{
       start_time_ms: System.system_time(:millisecond),
       metrics: %{}
     }}
  end

  # API

  @spec report_dimensional_metric(:count | :gauge | :summary, atom() | binary(), any, map()) ::
          :ok
  def report_dimensional_metric(type, name, value, attributes) when type in @valid_types do
    TelemetrySdk.DimensionalMetrics.HarvestCycle
    |> Harvest.HarvestCycle.current_harvester()
    |> GenServer.cast({:report, %{type: type, name: name, value: value, attributes: attributes}})
  end

  def gather_harvest,
    do:
      TelemetrySdk.DimensionalMetrics.HarvestCycle
      |> Harvest.HarvestCycle.current_harvester()
      |> GenServer.call(:gather_harvest)

  # do not accept more report messages when harvest has already been reported
  def handle_cast(_late_msg, :completed), do: {:noreply, :completed}

  def handle_cast({:report, metric}, state) do
    {:noreply, %{state | metrics: merge_metric(metric, state.metrics)}}
  end

  # do not resend metrics when harvest has already been reported
  def handle_call(_late_msg, _from, :completed), do: {:reply, :completed, :completed}

  def handle_call(:send_harvest, _from, state) do
    send_harvest(state)
    {:reply, :ok, :completed}
  end

  def handle_call(:gather_harvest, _from, state) do
    {:reply, build_dimensional_metric_data(state.metrics, state), state}
  end

  # Helpers

  defp merge_metric(
         %{type: :count, name: name, value: new_value, attributes: attributes} = metric,
         metrics_acc
       ) do
    attributes_hash = :erlang.phash2(attributes)

    case Map.get(metrics_acc, {:count, name, attributes_hash}) do
      nil ->
        Map.put(metrics_acc, {:count, name, attributes_hash}, metric)

      %{type: :count, value: current_value} = current_metric ->
        Map.put(metrics_acc, {:count, name, attributes_hash}, %{
          current_metric
          | value: current_value + new_value
        })
    end
  end

  defp merge_metric(
         %{type: :gauge, name: name, value: new_value, attributes: attributes} = metric,
         metrics_acc
       ) do
    attributes_hash = :erlang.phash2(attributes)

    case Map.get(metrics_acc, {:gauge, name, attributes_hash}) do
      nil ->
        Map.put(metrics_acc, {:gauge, name, attributes_hash}, metric)

      %{type: :gauge} = current_metric ->
        Map.put(metrics_acc, {:gauge, name, attributes_hash}, %{current_metric | value: new_value})
    end
  end

  defp merge_metric(
         %{type: :summary, name: name, value: new_value, attributes: attributes},
         metrics_acc
       ) do
    attributes_hash = :erlang.phash2(attributes)

    case Map.get(metrics_acc, {:summary, name, attributes_hash}) do
      nil ->
        new_summary = %{
          type: :summary,
          name: name,
          value: %{
            count: 1,
            min: new_value,
            max: new_value,
            sum: new_value
          },
          attributes: attributes
        }

        Map.put(metrics_acc, {:summary, name, attributes_hash}, new_summary)

      %{type: :summary} = current_metric ->
        Map.put(
          metrics_acc,
          {:summary, name, attributes_hash},
          %{current_metric | value: update_summary_value_map(current_metric, new_value)}
        )
    end
  end

  defp update_summary_value_map(
         %{type: :summary, value: value_map},
         new_value
       ) do
    updated_sum_count = %{value_map | sum: value_map.sum + new_value, count: value_map.count + 1}

    updated_min =
      if new_value < value_map.min,
        do: %{updated_sum_count | min: new_value},
        else: updated_sum_count

    if new_value > value_map.max, do: %{updated_min | max: new_value}, else: updated_min
  end

  defp send_harvest(state) do
    metrics = Map.values(state.metrics)
    TelemetrySdk.API.dimensional_metric(build_dimensional_metric_data(metrics, state))
    log_harvest(length(metrics))
  end

  defp log_harvest(harvest_size) do
    NewRelic.log(
      :debug,
      "Completed TelemetrySdk.DimensionalMetrics harvest - size: #{harvest_size}"
    )
  end

  defp build_dimensional_metric_data(metrics, state) do
    [
      %{
        metrics: metrics,
        common: common(state)
      }
    ]
  end

  defp common(%{start_time_ms: start_time_ms}) do
    %{"timestamp" => start_time_ms, "interval.ms" => @interval_ms}
  end
end
