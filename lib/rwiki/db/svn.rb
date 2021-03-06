require "svn/core"
require "svn/repos"
require "svn/client"
require "svn/wc"

require 'rwiki/db/file'
require "timeout"
require 'fileutils'

module RWiki
  module DB
    class Svn < File

      REVISION_STRINGS = %w(HEAD BASE COMMITTED PREV)

      TOO_DIRTY = 5
      
      class Error < StandardError
        attr_reader :update_result
        def initialize(error_message, update_result)
          super(error_message)
          @update_result = update_result
        end
      end
      
      def initialize(path)
        super(path)
        @path = ::File.join(@dir)
        @author = ENV["USER"] || "rwiki"
        @dirty_count = 0
        ctx = make_context
        ctx.cleanup(@path)
        ctx.update(@path)
        ctx.cleanup(@path)
        ctx.info(@path, nil, nil, false) do |path, info|
          @root_url = info.repos_root_URL
        end
      end

      def accept_commit_log?
        true
      end
      
      def revision(key)
        filename = fname(key)
        ctx = make_context
        rev = nil
        ctx.status(filename, nil, true, true) do |path, status|
          rev ||= status.entry.revision.to_s if status.entry
        end
        rev
      end

      def []=(*arg)
        key = arg.shift
        value = arg.pop
        rev = parse_rev(arg.shift)
        opt = {
          :query => arg.shift,
          :revision => rev,
        }
        # check_revision(k, rev)
        set(key, store(value), opt)
      end

      def close
      end

      def gc
        GC.start
      end
      
      def log(key, rev=nil)
        filename = fname(key)
        rev = parse_rev(rev || "COMMITTED")
        ctx = make_context
        message = ctx.log_message(filename, rev)
        if message.empty?
          nil
        else
          KCode.kconv(message)
        end
      end

      def logs(key)
        filename = fname(key)
        return [] unless versioned?(filename)
        ctx = make_context
        result = []
        receiver = Proc.new do |changed_paths, rev, author, date, message|
          log = Log.new(rev.to_s)
          log.author = author
          log.date = date
          log.commit_log = KCode.kconv(message) unless message.empty?
          result.unshift(log)
        end
        ctx.log(filename, 0, "HEAD", 0, false, false) do |*args|
          receiver.call(*args)
        end
        result
      end
      
      def move(old, new, src=nil, rev=nil, query=nil)
        opt ||= {}
        ctx = make_context(commit_message(query))
        old_filename = fname(old)
        new_filename = fname(new)
        synchronize do
          update(ctx, old, parse_rev(rev))
          if versioned?(new_filename)
            ctx.rm(new_filename)
            ctx.commit(new_filename)
          end
          ctx.mv_f(old_filename, new_filename)
          ctx.propdel("svn:mime-type", new_filename)
          if src
            ::File.open(new_filename, 'w') {|fp| fp.write(src)}
            ctx.update(new_filename)
          end
          ctx.commit([old_filename, new_filename])
        end
      rescue ::Svn::Error, Error
        # revert
        FileUtils.rm_f([old_filename, new_filename])
        ctx.revert([old_filename, new_filename])
        raise_revision_error($!, new, get(old, rev))
      end

      def annotate(key, rev=nil)
        filename = fname(key)
        rev = parse_rev(rev || "COMMITTED")
        ctx = make_context
        annotate = []
        ctx.blame(filename, 0, rev) do |line_no, revision, author, date, line|
          no = line_no + 1
          annotate << AnnotateLine.new(no, revision.to_s, author, date, line)
        end
        annotate
      end

      private
      def set(key, value, opt=nil)
        return if value.nil?
        filename = fname(key)
        ctx = make_context(commit_message(opt[:query]))
        rev = opt[:revision]
        if value.empty?
          ctx.rm_f(filename)
        else
          synchronize do
            update(ctx, key, rev)
            ::File.open(filename, 'w') {|fp| fp.write(value)}
            if versioned?(filename)
              ctx.update(filename)
            else
              ctx.add(filename)
              ctx.propdel("svn:mime-type", filename)
            end
          end
        end
        ctx.commit(filename)
      rescue ::Svn::Error, Error
        # revert
        ctx.revert(filename)
        raise_revision_error($!, key, value)
      end

      def raise_revision_error(error, key, value)
        raise RevisionError, <<__EOM__, caller
#{error.message}

#{key}: #{value}
__EOM__
      end
      
      def get(key, rev=nil)
        synchronize do
          filename = fname(key)
          if ::File.exist?(filename)
            if rev.nil? or rev == parse_rev(revision(key))
              ::File.open(filename, 'r') {|fp| fp.read}
            else
              make_context.cat(filename, parse_rev(rev))
            end
          else
            nil
          end
        end
      rescue Errno::ENOENT
        nil
      end

      def versioned?(filename)
        versioned = false
        ctx = make_context
        ctx.status(filename, nil, true, true) do |path, status|
          versioned = !status.entry.nil?
        end
        versioned
      end

      def to_revision(str)
        begin
          Integer(str)
        rescue ArgumentError
          str
        end
      end

      def committed_time(filename, rev)
        ctx = make_context
        time = nil
        receiver = Proc.new do |changed_paths, rev, author, date, message|
          time ||= date
        end
        ctx.log(filename, rev, rev, 1, false, true, &receiver)
        time
      end

      def format_diff(diff, key1, time1, key2, time2)
        result = diff.dup
        result.sub!(/\AIndex:.+\n=+\n/, '')
        label_re = "\\S+\\.rd(?:\\s*\\(\\S+\\))?"
        result.sub!(/^--- #{label_re}/) do |x|
          "--- #{key1}\t#{format_time(time1)}"
        end
        result.sub!(/^\+\+\+ #{label_re}/) do |x|
          "+++ #{key2}\t#{format_time(time2)}"
        end
        result
      end
      
      def make_context(log=nil)
        dirty
        if_dirty {gc}
        ctx = ::Svn::Client::Context.new
        set_log(ctx, log) if log
        ctx.add_username_prompt_provider(0) do |cred, realm, may_save|
          cred.username = @author
          cred.may_save = false
        end
        ctx
      end

      def set_log(ctx, log)
        log = KCode.to_utf8(log)
        ctx.set_log_msg_func do |items|
          [true, log]
        end
      end

      def locked?
        ::Svn::Wc.locked?(@path)
      end

      def parse_rev(rev)
        return "HEAD" if rev.nil?
        return rev if valid_revision_string?(rev)
        begin
          Integer(rev)
        rescue ArgumentError
          "HEAD"
        end
      end

      def valid_revision_string?(rev)
        REVISION_STRINGS.include?(rev)
      end

      def dirty
        @dirty_count += TOO_DIRTY / 5.0
      end

      def if_dirty
        if @dirty_count > TOO_DIRTY
          yield
          @dirty_count = 0
        end
      end

      def commit_message(query)
        if query
          commit_message = query['commit_log'].to_s
        else
          commit_message = ''
        end
      end

      def update(ctx, key, rev)
        begin
          ctx.update(fname(key), rev)
        rescue ::Svn::Error::FS_NO_SUCH_REVISION
          ctx.cleanup(@path) if locked?
          raise Error.new("error while update to revision `#{rev}'", get(key))
        end
      end

      def diff_from_epoch(key, rev)
        filename = fname(key)
        rev = to_revision(rev)
        time = committed_time(filename, rev)
        ctx = make_context
        contents = []
        ctx.cat(filename, rev).each_line do |line|
          contents << "+#{line}"
        end
        null_title = _("(not exist)")
        rev_title = _("(revision %d)") % rev
        result = "--- #{null_title}\n"
        result << "+++ #{key} #{format_time(time)} #{rev_title}\n"
        result << "@@ -0,0 +1,#{contents.size}\n"
        result << contents.join("")
        result
      end

      def diff_between(key, rev1, rev2=nil)
        filename = fname(key)
        rev1 = to_revision(rev1)
        rev2 = to_revision(rev2 || 'HEAD')
        out_tmp = Tempfile.new("rwiki-db-svn")
        err_tmp = Tempfile.new("rwiki-db-svn")
        ctx = make_context
        key, filename1, key2, filename2 = diff_info(key, filename, rev1, rev2)
        ctx.diff([], filename2, rev1, filename1, rev2,
                 out_tmp.path, err_tmp.path)
        out_tmp.close
        out_tmp.open
        time1 = committed_time(filename, rev1)
        time2 = committed_time(filename, rev2)
        format_diff(out_tmp.read, key2, time1, key, time2)
      end

      def diff_info(key, filename, rev1, rev2)
        key2 = nil
        filename2 = nil
        args = [filename, "HEAD", rev1, 0, true, false]
        make_context.log(*args) do |changed_paths, rev, *rest|
          break if rev == rev1
          if filename2 and rev == rev2
            key = key2
            filename = filename2
          end
          changed_paths.each do |path, changed_path|
            break unless changed_path.respond_to?(:copyfrom_path)
            svn_path = changed_path.copyfrom_path
            if svn_path
              key2 = svn_path_to_key(svn_path)
              filename2 = "#{@root_url}#{encode_svn_path(svn_path)}"
              break
            end
          end
        end
        key2 ||= key
        filename2 ||= filename
        [key, filename, key2, filename2]
      end

      def svn_path_to_key(path)
        fname_to_key(path.split("/").last)
      end

      def svn_path_to_filename(path)
        fname(svn_path_to_key(path))
      end

      def encode_svn_path(path)
        path.split("/").collect do |segment|
          url_encode(segment)
        end.join("/")
      end

      def format_time(time)
        time.xmlschema
      end
    end
  end
end
