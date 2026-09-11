module Blazer
  module Adapters
    class BaseAdapter
      attr_reader :data_source

      def initialize(data_source)
        @data_source = data_source
      end

      def run_statement(statement, comment)
        # required
      end

      def supports_streaming?
        false # optional
      end

      # required when supports_streaming? is true
      # yields [columns, rows] per batch and returns the error message, or nil
      def run_statement_streaming(statement, comment, bind_params = [], batch_size: nil, &block)
        raise Blazer::Error, "Streaming not supported"
      end

      def quoting
        # required, how to quote variables
        # :backslash_escape - single quote strings and convert ' to \' and \ to \\
        # :single_quote_escape - single quote strings and convert ' to ''
        # ->(value) { ... } - custom method
      end

      def parameter_binding
        # optional, but recommended when possible for security
        # if specified, quoting is only used for display
        # :positional - ?
        # :numeric - $1
        # ->(statement, values) { ... } - custom method
      end

      def tables
        [] # optional, but nice to have
      end

      def schema
        [] # optional, but nice to have
      end

      def preview_statement
        "" # also optional, but nice to have
      end

      def reconnect
        # optional
      end

      def cost(statement)
        # optional
      end

      def explain(statement)
        # optional
      end

      def cancel(run_id)
        # optional
      end

      def cachable?(statement)
        true # optional
      end

      def supports_cohort_analysis?
        false # optional
      end

      def cohort_analysis_statement(statement, period:, days:)
        # optional
      end

      protected

      def settings
        @data_source.settings
      end
    end
  end
end
