defmodule NewRelic.Error.MetadataReporter do
  @moduledoc false

  alias NewRelic.Util
  alias NewRelic.Harvest.Collector

  import NewRelic.ConditionalCompile

  # Before elixir 1.15, ignore terminating errors so they don't get reported twice
  before_elixir_version("1.15.0", def(report_error(_, {{_, :terminating}, _}), do: nil))

  def report_error(:transaction, {_cause, metadata}) do
    NewRelic.add_attributes(temp_data_transaction_metadata: inspect(metadata))
    kind = :error
    {_exception_type, reason, stacktrace, _expected} = parse_reason(metadata.reason)
    process_name = parse_process_name(metadata[:registered_name], stacktrace)

    NewRelic.add_attributes(process: process_name)

    NewRelic.Transaction.Reporter.error(%{
      kind: kind,
      reason: reason,
      stack: stacktrace
    })
  end

  def report_error(:process, {_cause, metadata}) do
    NewRelic.add_attributes(temp_data_process_metadata: inspect(metadata))
    {exception_type, reason, stacktrace, expected} = parse_reason(metadata.reason)

    process_name = parse_process_name(metadata[:registered_name], stacktrace)
    automatic_attributes = NewRelic.Config.automatic_attributes()
    formatted_stacktrace = Util.Error.format_stacktrace(stacktrace, nil)

    Collector.ErrorTrace.Harvester.report_error(%NewRelic.Error.Trace{
      timestamp: System.system_time(:millisecond) / 1_000,
      error_type: exception_type,
      message: reason,
      expected: expected,
      stack_trace: formatted_stacktrace,
      transaction_name: "OtherTransaction/Elixir/ElixirProcess//#{process_name}",
      user_attributes:
        Map.merge(automatic_attributes, %{
          process: process_name
        })
    })

    Collector.TransactionErrorEvent.Harvester.report_error(%NewRelic.Error.Event{
      timestamp: System.system_time(:millisecond) / 1_000,
      error_class: exception_type,
      error_message: reason,
      expected: expected,
      transaction_name: "OtherTransaction/Elixir/ElixirProcess//#{process_name}",
      user_attributes:
        Map.merge(automatic_attributes, %{
          process: process_name,
          stacktrace: Enum.join(formatted_stacktrace, "\n")
        })
    })

    unless expected do
      NewRelic.report_metric({:supportability, :error_event}, error_count: 1)
      NewRelic.report_metric(:error, error_count: 1)
    end
  end

  defp parse_reason({%type{message: message} = exception, stacktrace}) do
    NewRelic.add_attributes(temp_data_parse_exception_with_type: inspect(exception))
    expected = parse_error_expected(exception)
    type = inspect(type)
    NewRelic.add_attributes(temp_data_type_for_parse_exception_with_type: type)
    NewRelic.add_attributes(temp_data_expected_for_parse_exception_with_type: expected)
    reason = "(#{type}) #{message}"

    NewRelic.add_attributes(temp_data_reason_for_parse_exception_with_type: reason)

    {type, reason, stacktrace, expected}
  end

  defp parse_reason({exception, stacktrace}) do
    NewRelic.add_attributes(temp_data_parse_exception_without_type: inspect(exception))
    exception = Exception.normalize(:error, exception, stacktrace)
    type = inspect(exception.__struct__)
    NewRelic.add_attributes(temp_data_type_for_parse_exception_without_type: type)
    message = Exception.message(exception)
    reason = "(#{type}) #{message}"

    {type, reason, stacktrace, false}
  end

  defp parse_process_name([], [{module, _f, _a, _} | _]), do: inspect(module)
  defp parse_process_name([], _stacktrace), do: "UnknownProcess"
  defp parse_process_name(registered_name, _stacktrace), do: inspect(registered_name)

  defp parse_error_expected(%{expected: true}), do: true
  defp parse_error_expected(_), do: false
end
