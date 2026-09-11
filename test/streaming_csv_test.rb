require_relative "test_helper"

class StreamingCsvTest < ActionDispatch::IntegrationTest
  # a row per type that the CSV writer treats specially, plus enough rows to
  # span several cursor batches
  MIXED_STATEMENT = <<~SQL
    SELECT
      n AS id,
      'a,b"c' || chr(10) || '日本語' AS text,
      NULLIF(n, n) AS blank,
      (n / 3.0)::numeric AS amount,
      (n % 2 = 0) AS flag,
      TIMESTAMP '2020-01-02 03:04:05' + (n || ' seconds')::interval AS created_at
    FROM generate_series(1, 2500) n
  SQL

  def setup
    super
    skip unless postgresql?
    Rails.cache.clear
    Blazer::Audit.delete_all
    Blazer::Query.delete_all
  end

  def test_streams_by_default
    assert Blazer.streaming_csv
    assert Blazer.data_sources["main"].supports_streaming?
  end

  def test_output_matches_non_streaming
    streamed = csv_body(MIXED_STATEMENT)
    buffered = with_option(:streaming_csv, false) { csv_body(MIXED_STATEMENT) }
    assert_equal buffered, streamed
  end

  def test_output_matches_non_streaming_with_variables
    query = create_query(name: "Cities", statement: "SELECT 1 AS id, {name} AS city")
    streamed = csv_body(query.statement, query_id: query.id, variables: {name: "Chicago"})
    buffered = with_option(:streaming_csv, false) do
      csv_body(query.statement, query_id: query.id, variables: {name: "Chicago"})
    end
    assert_equal "id,city\n1,Chicago\n", streamed
    assert_equal buffered, streamed
  end

  def test_no_rows_writes_header_only
    assert_equal "id\n", csv_body("SELECT 1 AS id WHERE 1 = 0")
  end

  def test_content_length_matches_body
    body = csv_body(MIXED_STATEMENT)
    assert_equal body.bytesize.to_s, response.headers["Content-Length"]
    assert_equal "text/csv; charset=utf-8", response.headers["Content-Type"]
    assert_equal "attachment; filename=\"query.csv\"; filename*=UTF-8''query.csv", response.headers["Content-Disposition"]
  end

  def test_trailing_semicolon
    assert_equal "id\n1\n", csv_body("SELECT 1 AS id;")
  end

  def test_trailing_line_comment
    assert_equal "id\n1\n", csv_body("SELECT 1 AS id -- a note")
  end

  def test_failure_after_first_batch_is_reported
    # the cursor hands back 1000 good rows before the division fails: the
    # download must not pass those off as the whole result
    assert_raises(Blazer::Error) do
      csv_body("SELECT n, (1 / (1500 - n))::int FROM generate_series(1, 3000) n")
    end
  end

  def test_error_message_matches_non_streaming
    # the offending token sits on a line whose number is two digits wide, so the
    # caret has to move with the number when the position is shifted back
    statement = ["SELECT 1 AS a", *Array.new(10) { "UNION ALL SELECT 1" }, "UNION ALL SELECT 1 456"].join("\n")
    streamed = error_message(statement)
    buffered = with_option(:streaming_csv, false) { error_message(statement) }

    assert_match "LINE 12: UNION ALL SELECT 1 456", streamed
    assert_equal buffered, streamed
  end

  def test_falls_back_when_streaming_unsupported
    with_setting("use_transaction", false) do
      refute Blazer.data_sources["main"].supports_streaming?
      assert_equal "id\n1\n", csv_body("SELECT 1 AS id")
    end
  end

  def test_download_reflects_current_data_even_with_caching_on
    # streaming never reads or writes the result cache, so two downloads of the
    # same statement see the rows as they are now
    with_caching({"mode" => "all"}) do
      create_query(name: "First")
      assert_equal "count\n1\n", csv_body("SELECT COUNT(*) AS count FROM blazer_queries")
      create_query(name: "Second")
      assert_equal "count\n2\n", csv_body("SELECT COUNT(*) AS count FROM blazer_queries")
    end
  end

  def test_html_is_unaffected
    run_query "SELECT 1 AS id, 'Chicago' AS city"
    assert_match "Chicago", response.body
  end

  def test_audits_the_download
    csv_body("SELECT 1 AS id")
    assert_equal 1, Blazer::Audit.count
  end

  def test_yields_one_batch_at_a_time
    batches = each_batch("SELECT n FROM generate_series(1, 5) n", batch_size: 2)
    assert_equal [2, 2, 1], batches.map(&:last).map(&:size)
  end

  def test_result_that_fills_the_last_batch_exactly
    batches = each_batch("SELECT n FROM generate_series(1, 4) n", batch_size: 2)
    assert_equal [2, 2, 0], batches.map(&:last).map(&:size)
    assert_equal [[1], [2], [3], [4]], batches.flat_map(&:last)
  end

  def test_columns_are_known_before_any_row
    batches = each_batch("SELECT 1 AS id WHERE 1 = 0", batch_size: 2)
    assert_equal [["id"]], batches.map(&:first)
  end

  def test_query_cache_does_not_replay_a_batch
    # every FETCH is the same SQL but a different batch of rows, so a cached
    # first batch would be handed back for the rest of the cursor
    adapter.send(:connection_model).cache do
      batches = each_batch("SELECT n FROM generate_series(1, 5) n", batch_size: 2)
      assert_equal [[1], [2], [3], [4], [5]], batches.flat_map(&:last)
    end
  end

  def test_consumer_failure_is_not_reported_as_a_query_error
    assert_raises(IOError) do
      adapter.run_statement_streaming("SELECT 1", "test") { raise IOError, "disk full" }
    end
  end

  def test_tempfile_body_streams_then_removes_the_file
    tempfile = Tempfile.new(["blazer", ".csv"], binmode: true)
    tempfile.write("id\n1\n")
    tempfile.flush
    path = tempfile.path

    body = Blazer::TempfileBody.new(tempfile)
    chunks = []
    body.each { |chunk| chunks << chunk }
    assert_equal "id\n1\n", chunks.join

    body.close
    refute File.exist?(path)
  end

  private

  # compared as bytes: a download is a byte stream, and the streamed body hands
  # back binary chunks where send_data hands back a UTF-8 string
  def csv_body(statement, **params)
    run_query(statement, format: "csv", **params)
    response.body.b
  end

  def error_message(statement)
    assert_raises(Blazer::Error) { csv_body(statement) }.message
  end

  def each_batch(statement, batch_size:, max_batches: 100)
    batches = []
    error = adapter.run_statement_streaming(statement, "test", [], batch_size: batch_size) do |columns, rows|
      batches << [columns, rows]
      # a cursor that never reports a short batch would otherwise hang the suite
      raise "cursor did not reach its end after #{max_batches} batches" if batches.size > max_batches
    end
    assert_nil error
    batches
  end

  def adapter
    Blazer.data_sources["main"].send(:adapter_instance)
  end

  def with_caching(value)
    data_source = Blazer.data_sources["main"]
    begin
      data_source.instance_variable_set(:@cache, value)
      yield
    ensure
      data_source.remove_instance_variable(:@cache)
    end
  end

  def with_setting(name, value)
    settings = Blazer.data_sources["main"].settings
    had_key = settings.key?(name)
    previous = settings[name]
    begin
      settings[name] = value
      yield
    ensure
      had_key ? settings[name] = previous : settings.delete(name)
    end
  end
end
