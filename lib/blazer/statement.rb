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

    # The statement with a trailing semicolon removed, or nil when wrapping it
    # in an outer SELECT would not be safe.
    #
    # Only a single statement starting with SELECT or WITH can be wrapped:
    # anything else either changes meaning under a wrapper (INSERT, EXPLAIN) or
    # stops parsing (two statements separated by a semicolon).
    #
    # Finding that semicolon means walking the SQL rather than matching it,
    # because a semicolon inside a string literal or a comment is not a
    # separator. Every branch below bails out to nil the moment it meets syntax
    # it cannot account for: failing to wrap only leaves the previous behavior
    # in place, while wrapping SQL we misread would silently change what the
    # user asked for.
    def row_limit_source
      return @row_limit_source if defined?(@row_limit_source)

      @row_limit_source = scan_row_limit_source
    end

    def scan_row_limit_source
      sql = statement.to_s
      i = 0
      n = sql.length

      while i < n
        case sql[i]
        when "-"
          if sql[i + 1] == "-"
            i = sql.index("\n", i) || n
          else
            i += 1
          end
        when "/"
          if sql[i + 1] == "*"
            i = skip_block_comment(sql, i) or return nil
          else
            i += 1
          end
        when "'", '"', "`"
          i = skip_quoted(sql, i) or return nil
        when "$"
          i = skip_dollar_quoted(sql, i) or return nil
        when ";"
          # A separator is only acceptable as the very last thing in the
          # statement; anything after it makes this multiple statements.
          return blank_from?(sql, i + 1) ? leading_select(sql[0...i]) : nil
        else
          i += 1
        end
      end

      leading_select(sql)
    end

    def leading_select(sql)
      # Leading comments are common enough (Blazer writes its own markers this
      # way) that they have to be skipped before the first keyword is read.
      rest = sql.sub(/\A(?:\s|--[^\n]*\n|\/\*.*?\*\/)+/m, "")
      /\A(?:SELECT|WITH)\b/i.match?(rest) ? sql : nil
    end

    # Index just past the comment starting at i, or nil when it never closes.
    #
    # Nesting follows PostgreSQL. MySQL ends the comment at the first `*/`, so a
    # nested comment there is read as unterminated and gives up on wrapping,
    # which is the harmless direction.
    def skip_block_comment(sql, i)
      depth = 0
      n = sql.length
      while i < n
        if sql[i] == "/" && sql[i + 1] == "*"
          depth += 1
          i += 2
        elsif sql[i] == "*" && sql[i + 1] == "/"
          depth -= 1
          i += 2
          return i if depth.zero?
        else
          i += 1
        end
      end
      nil
    end

    # Index just past the quoted run starting at i, or nil when it never closes.
    def skip_quoted(sql, i)
      quote = sql[i]
      n = sql.length
      i += 1
      while i < n
        if sql[i] == "\\" && quote == "'"
          # MySQL escapes with backslashes. PostgreSQL under
          # standard_conforming_strings does not, but skipping the next
          # character only loses the closing quote when a literal ends in a
          # backslash, and that lands on nil rather than a bad wrap.
          i += 2
        elsif sql[i] == quote
          return i + 1 unless sql[i + 1] == quote
          i += 2 # doubled quote escapes itself
        else
          i += 1
        end
      end
      nil
    end

    # Index just past a PostgreSQL dollar-quoted string starting at i, i + 1
    # when the dollar sign does not open one, or nil when the tag never closes.
    def skip_dollar_quoted(sql, i)
      n = sql.length
      j = i + 1
      j += 1 while j < n && /[A-Za-z0-9_]/.match?(sql[j])
      return i + 1 unless j < n && sql[j] == "$"
      # Tags cannot start with a digit, which is what keeps $1 and the rest of
      # the numeric bind placeholders from reading as an opening tag.
      return i + 1 if j > i + 1 && /[0-9]/.match?(sql[i + 1])

      tag = sql[i..j]
      close = sql.index(tag, j + 1)
      close && close + tag.length
    end

    # Whether only whitespace and comments remain from i on.
    def blank_from?(sql, i)
      n = sql.length
      while i < n
        case sql[i]
        when " ", "\t", "\r", "\n", "\f", "\v"
          i += 1
        when "-"
          return false unless sql[i + 1] == "-"
          i = sql.index("\n", i) || n
        when "/"
          return false unless sql[i + 1] == "*"
          i = skip_block_comment(sql, i) or return false
        else
          return false
        end
      end
      true
    end
  end
end
