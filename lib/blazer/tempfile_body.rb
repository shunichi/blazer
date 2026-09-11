module Blazer
  # Rack body that streams a generated file and deletes it once the response has
  # been written.
  #
  # Not send_file: nothing would then own the Tempfile. Its finalizer can unlink
  # the file before the server reads the path, and handing over a bare path
  # instead leaves the file behind. Holding the handle here ties the file's life
  # to the response rather than to the GC.
  #
  # Deliberately responds to neither to_ary nor to_path. to_ary makes Rack's ETag
  # middleware buffer the body to digest it, and to_path makes Rack::Sendfile
  # hand the path to the web server, which would read it after #close has
  # already removed it.
  class TempfileBody
    CHUNK_SIZE = 64 * 1024

    def initialize(tempfile)
      @tempfile = tempfile
    end

    def each
      @tempfile.rewind
      while (chunk = @tempfile.read(CHUNK_SIZE))
        yield chunk
      end
    end

    # Reached through ActionDispatch::Response#abort, which is what Rack's close
    # maps to, so this also runs when the client disconnects partway through.
    def close
      @tempfile.close!
    end
  end
end
