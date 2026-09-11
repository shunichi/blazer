require_relative "test_helper"

class RowLimitTest < ActionDispatch::IntegrationTest
  # 20 rows without a table or a dialect-specific generator
  ROWS = <<~SQL.strip
    WITH RECURSIVE nums(n) AS (
      SELECT 1
      UNION ALL
      SELECT n + 1 FROM nums WHERE n < 20
    )
    SELECT n FROM nums
  SQL

  def setup
    super
    Blazer::Audit.delete_all
  end

  # which statements can be wrapped

  def test_select
    assert_equal "SELECT * FROM (\nSELECT 1\n) AS blazer_row_limit LIMIT 5", wrap("SELECT 1")
  end

  def test_with
    assert_wrapped "WITH t AS (SELECT 1) SELECT * FROM t"
  end

  def test_trailing_semicolon
    assert_equal "SELECT * FROM (\nSELECT 1\n) AS blazer_row_limit LIMIT 5", wrap("SELECT 1;")
  end

  def test_trailing_semicolon_then_comment
    assert_equal "SELECT * FROM (\nSELECT 1\n) AS blazer_row_limit LIMIT 5", wrap("SELECT 1; -- done")
  end

  def test_trailing_line_comment
    assert_equal "SELECT * FROM (\nSELECT 1\n-- note\n) AS blazer_row_limit LIMIT 5", wrap("SELECT 1\n-- note")
  end

  def test_leading_block_comment
    assert_wrapped "/* report */ SELECT 1"
  end

  def test_leading_line_comment
    assert_wrapped "-- report\nSELECT 1"
  end

  def test_semicolon_in_string
    assert_wrapped "SELECT 'a;b'"
  end

  def test_semicolon_in_quoted_identifier
    assert_wrapped %{SELECT 1 AS "a;b"}
  end

  def test_semicolon_in_line_comment
    assert_wrapped "SELECT 1 -- a;b"
  end

  def test_semicolon_in_block_comment
    assert_wrapped "SELECT 1 /* a;b */"
  end

  def test_doubled_quote_escape
    assert_wrapped "SELECT 'it''s'"
  end

  def test_dollar_quoted_string
    assert_wrapped "SELECT $$a;b$$"
  end

  def test_tagged_dollar_quoted_string
    assert_wrapped "SELECT $tag$a;b$tag$"
  end

  def test_numeric_placeholder
    assert_wrapped "SELECT * FROM t WHERE id = $1"
  end

  def test_multiple_statements
    assert_nil wrap("SELECT 1; SELECT 2")
  end

  def test_statement_after_trailing_comment
    assert_nil wrap("SELECT 1; /* c */ SELECT 2")
  end

  def test_insert
    assert_nil wrap("INSERT INTO t VALUES (1)")
  end

  def test_update
    assert_nil wrap("UPDATE t SET a = 1")
  end

  def test_explain
    assert_nil wrap("EXPLAIN SELECT 1")
  end

  def test_parenthesized_union
    assert_nil wrap("(SELECT 1) UNION (SELECT 2)")
  end

  def test_unterminated_string
    assert_nil wrap("SELECT 'a")
  end

  def test_unterminated_block_comment
    assert_nil wrap("SELECT 1 /* a")
  end

  # what the run action limits

  def test_limits_rows
    with_option(:row_limit, 5) do
      run_query ROWS
    end
    assert_match "First", response.body
    assert_match "5 rows", response.body
  end

  def test_limit_reaches_the_database
    executed = capture_statements do
      with_option(:row_limit, 5) { run_query ROWS }
    end
    assert_equal 1, executed.count { |s| s.include?("blazer_row_limit") }
    assert_match(/LIMIT 6\z/, executed.find { |s| s.include?("blazer_row_limit") })
  end

  def test_under_limit
    with_option(:row_limit, 50) do
      run_query ROWS
    end
    refute_match "First", response.body
    assert_match "20 rows", response.body
  end

  def test_off_by_default
    executed = capture_statements { run_query ROWS }
    assert_nil Blazer.row_limit
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
    assert_match "20 rows", response.body
  end

  def test_disabled
    executed = capture_statements do
      with_option(:row_limit, nil) { run_query ROWS }
    end
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
  end

  def test_csv_not_limited
    with_option(:row_limit, 5) do
      run_query ROWS, format: "csv"
    end
    assert_equal 21, response.body.lines.size
  end

  def test_forecast_not_limited
    query = create_query(statement: ROWS)
    executed = capture_statements do
      with_option(:forecasting, "prophet") do
        with_option(:row_limit, 5) do
          run_query ROWS, query_id: query.id, forecast: "t"
        end
      end
    end
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
  end

  def test_unwrappable_statement_is_not_limited
    executed = capture_statements do
      with_option(:row_limit, 1) { run_query "(SELECT 1) UNION (SELECT 2)" }
    end
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
    refute_match "First", response.body
    assert_match "2 rows", response.body
  end

  def test_audit_records_statement_as_written
    with_option(:row_limit, 5) { run_query "SELECT 1" }
    assert_equal "SELECT 1", Blazer::Audit.last.statement
  end

  def test_async
    executed = nil
    jobs = capture_jobs do
      executed = capture_statements do
        with_option(:async, true) do
          with_option(:row_limit, 5) { run_query ROWS }
        end
      end
    end
    assert_equal 1, jobs.count { |job| job.is_a?(Blazer::RunStatementJob) }
    assert_equal 1, executed.count { |s| s.include?("blazer_row_limit") }
    assert_match "First", response.body
  end

  def test_async_audit_records_statement_as_written
    jobs = capture_jobs do
      with_option(:async, true) do
        with_option(:row_limit, 5) { run_query "SELECT 1" }
      end
    end
    assert_equal 1, jobs.count { |job| job.is_a?(Blazer::RunStatementJob) }
    assert_equal "SELECT 1", Blazer::Audit.last.statement
  end

  def test_cohort_analysis_not_limited
    executed = capture_statements do
      with_option(:row_limit, 5) do
        run_query "SELECT 1 AS user_id, NOW() AS conversion_time /* cohort analysis */", query_id: 1
      end
    end
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
  end

  def test_cohort_rows_limited
    executed = capture_statements do
      with_option(:row_limit, 5) do
        run_query "SELECT 1 AS user_id, NOW() AS conversion_time /* cohort analysis */"
      end
    end
    assert_match(/LIMIT 1001\z/, executed.find { |s| s.include?("blazer_row_limit") })
  end

  def test_cohort_rows_not_limited_by_default
    executed = capture_statements do
      run_query "SELECT 1 AS user_id, NOW() AS conversion_time /* cohort analysis */"
    end
    assert_empty executed.select { |s| s.include?("blazer_row_limit") }
  end

  private

  def wrap(statement, limit: 5)
    statement = Blazer::Statement.new(statement, "main")
    statement.apply_row_limit(limit) ? statement.statement : nil
  end

  def assert_wrapped(statement)
    wrapped = wrap(statement)
    refute_nil wrapped, "expected #{statement.inspect} to be wrapped"
    assert_match "blazer_row_limit", wrapped
  end

  # RunStatementJob pins itself to the async queue adapter, so it never reaches
  # the test adapter that assert_performed_jobs reads.
  def capture_jobs
    jobs = Queue.new
    subscriber = ->(*args) { jobs << args.last[:job] }
    ActiveSupport::Notifications.subscribed(subscriber, "perform.active_job") do
      yield
    end
    Array.new(jobs.size) { jobs.pop }
  end

  def capture_statements
    executed = []
    with_option(:transform_statement, ->(_data_source, statement) { executed << statement.dup }) do
      yield
    end
    executed
  end
end
