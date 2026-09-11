module Blazer
  class RunStatement
    def perform(statement, options = {})
      query = options[:query]

      data_source = statement.data_source
      statement.bind

      audit = create_audit(statement, options)

      start_time = Blazer.monotonic_time
      result = data_source.run_statement(statement, options)
      duration = Blazer.monotonic_time - start_time

      finish_audit(audit, data_source, statement, duration, error: result.error, timed_out: result.timed_out?, cached: result.cached?)

      if query && !result.timed_out? && !result.cached? && !query.variables.any?
        query.checks.each do |check|
          check.update_state(result)
        end
      end

      result
    end

    # Streams the result in batches, yielding [columns, rows] for each. Returns
    # the error message, or nil when the query succeeded.
    #
    # Unlike perform, this leaves the query's checks alone: a check needs the
    # whole result to decide its state, and materializing it here would undo the
    # reason for streaming. Checks run on their own schedule anyway.
    def perform_streaming(statement, options = {}, &block)
      data_source = statement.data_source
      statement.bind

      audit = create_audit(statement, options)

      start_time = Blazer.monotonic_time
      error = data_source.run_statement_streaming(statement, options, &block)
      duration = Blazer.monotonic_time - start_time

      finish_audit(audit, data_source, statement, duration, error: error, timed_out: error == Blazer::TIMEOUT_MESSAGE, cached: false)

      error
    end

    private

    def create_audit(statement, options)
      return nil unless Blazer.audit

      audit_statement = statement.bind_statement
      audit_statement += "\n\n#{statement.bind_values.to_json}" if statement.bind_values.any?
      audit = Blazer::Audit.new(statement: audit_statement)
      audit.query = options[:query]
      audit.data_source = statement.data_source.id
      # only set user if present to avoid error with Rails 7.1 when no user model
      audit.user = options[:user] unless options[:user].nil?
      audit.save!
      audit
    end

    def finish_audit(audit, data_source, statement, duration, error:, timed_out:, cached:)
      return unless audit

      audit.duration = duration if audit.respond_to?(:duration=)
      audit.error = error if audit.respond_to?(:error=)
      audit.timed_out = timed_out if audit.respond_to?(:timed_out=)
      audit.cached = cached if audit.respond_to?(:cached=)
      if !cached && duration >= 10
        audit.cost = data_source.cost(statement) if audit.respond_to?(:cost=)
      end
      audit.save! if audit.changed?
    end
  end
end
