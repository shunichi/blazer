module Blazer
  class Statement
    attr_reader :statement, :data_source, :bind_statement, :bind_values
    attr_accessor :values

    def initialize(statement, data_source = nil)
      @statement = statement
      @data_source = data_source.is_a?(String) ? Blazer.data_sources[data_source] : data_source
      @values = {}
    end

    def variables
      # strip commented out lines
      # and regex {1} or {1,2}
      @variables ||= statement.to_s.gsub(/\-\-.+/, "").gsub(/\/\*.+\*\//m, "").scan(/\{\w*?\}/i).map { |v| v[1...-1] }.reject { |v| /\A\d+(\,\d+)?\z/.match(v) || v.empty? }.uniq
    end

    def add_values(var_params)
      variables.each do |var|
        value = var_params[var].presence
        value = nil unless value.is_a?(String) # ignore arrays and hashes
        if value
          if ["start_time", "end_time"].include?(var)
            value = value.to_s.gsub(" ", "+") # fix for Quip bug
          end

          if var.end_with?("_at")
            begin
              value = Blazer.time_zone.parse(value)
            rescue
              # do nothing
            end
          end

          unless value.is_a?(ActiveSupport::TimeWithZone)
            if value.match?(/\A\d+\z/)
              # check no leading zeros (when not zero)
              if value == value.to_i.to_s
                value = value.to_i
              end
            elsif value.match?(/\A\d+\.\d+\z/)
              value = value.to_f
            end
          end
        end
        value = Blazer.transform_variable.call(var, value) if Blazer.transform_variable
        @values[var] = value
      end
    end

    def cohort_analysis?
      /\/\*\s*cohort analysis\s*\*\//i.match?(statement)
    end

    def apply_cohort_analysis(period:, days:)
      @statement = data_source.cohort_analysis_statement(statement, period: period, days: days).sub("{placeholder}") { statement }
    end

    # Whether a row limit can be put on this statement. Callers that show the
    # limit to the user have to ask before the statement runs, and a false here
    # means the result will hold every row the query produces.
    def row_limit_applicable?
      !!(data_source&.supports_row_limit? && row_limit_source)
    end

    # Wraps the statement so the database stops producing rows past the limit,
    # replacing it in place. Returns false and leaves the statement alone when
    # the SQL cannot be wrapped safely.
    def apply_row_limit(limit)
      return false if @unlimited # already wrapped; row_limit_source is memoized

      source = row_limit_source
      return false unless source && data_source&.supports_row_limit?

      # Kept so audits can record the statement as written. The limit is
      # Blazer's doing rather than something the user asked for, and copying the
      # wrapper into every audit row would make the log harder to read and to
      # replay.
      @unlimited = dup
      @statement = data_source.row_limit_statement(source, limit: limit)
      true
    end

    # should probably transform before cohort analysis
    # but keep previous order for now
    def transformed_statement
      statement = self.statement.dup
      Blazer.transform_statement.call(data_source, statement) if Blazer.transform_statement
      statement
    end

    def bind
      @bind_statement, @bind_values = data_source.bind_params(transformed_statement, values)
      @unlimited&.bind
    end

    # The bound statement to record in audits.
    #
    # bind_values is shared with the wrapped statement rather than tracked
    # separately: the wrapper holds no variables, so binding either text finds
    # the same ones in the same order.
    def audit_statement
      @unlimited ? @unlimited.bind_statement : bind_statement
    end

    def display_statement
      data_source.sub_variables(transformed_statement, values)
    end

    def clear_cache
      bind if bind_statement.nil?
      data_source.clear_cache(self)
    end

    private

    # Comments and quoted runs, so a semicolon inside one is not read as a
    # statement separator.
    COMMENTS_AND_LITERALS = /
      --[^\n]*        | # line comment
      \/\*.*?\*\/     | # block comment
      '(?:[^']|'')*'  | # string literal
      "(?:[^"]|"")*"  | # quoted identifier
      `(?:[^`]|``)*`    # quoted identifier, MySQL
    /xm

    # The statement with a trailing semicolon removed, or nil when wrapping it
    # in an outer SELECT would not be safe.
    #
    # Only a single statement starting with SELECT or WITH can be wrapped.
    # Blazer does not reject writes — nothing inspects the statement, and the
    # transaction around a query is what undoes them — so an INSERT reaching
    # here is a statement that works today, and an INSERT or an EXPLAIN inside
    # FROM is a syntax error. Several statements are ruled out for the same
    # reason: Blazer runs those too, returning the last result.
    #
    # Blanking is deliberately approximate. Syntax it does not model — nested
    # block comments, backslash escapes, dollar quotes — leaves the semicolon
    # visible rather than hiding one, so the statement reads as several and goes
    # unwrapped. That asymmetry is what makes the shortcut safe: not wrapping
    # leaves today's behavior in place, while wrapping SQL we misread would
    # change what the user asked for.
    def row_limit_source
      return @row_limit_source if defined?(@row_limit_source)

      @row_limit_source = scan_row_limit_source
    end

    def scan_row_limit_source
      sql = statement.to_s
      # Blanked to the same length, so offsets still point into the original.
      blanked = sql.gsub(COMMENTS_AND_LITERALS) { |match| " " * match.length }

      semicolon = blanked.index(";")
      if semicolon
        return nil unless blanked[(semicolon + 1)..].strip.empty?

        sql = sql[0...semicolon]
        blanked = blanked[0...semicolon]
      end

      /\A\s*(?:SELECT|WITH)\b/i.match?(blanked) ? sql : nil
    end
  end
end
