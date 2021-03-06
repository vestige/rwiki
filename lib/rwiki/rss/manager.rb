require "net/http"
require "open-uri"
require "uri"
require "thread"
require "time"
require "timeout"

require "rss/parser"
require "rss/1.0"
require "rss/2.0"
require "rss/dublincore"
require "rss/content"

require "rwiki/rw-lib"

module RWiki
  module RSS

    MINIMUM_EXPIRE = 60 * 60 unless const_defined?(:MINIMUM_EXPIRE)
    EXPIRE = 2 * 60 * 60 unless const_defined?(:EXPIRE)

    class Error < StandardError; end
    class InvalidResourceError < Error; end
    
    class Manager

      include Enumerable

      VERSION = '$Id$'
      
      HTTP_HEADER = {
        "User-Agent" => "RWiki's RSS Manager version #{VERSION}. " <<
        "Using RSS parser version is #{::RSS::VERSION}.",
      }

      @@cache = Hash.new({})
      @@mutex = Mutex.new

      class << self
        
        def forget(expire=EXPIRE)
          expire = EXPIRE if expire.to_i < MINIMUM_EXPIRE
          @@mutex.synchronize do
            @@cache.delete_if do |uri, values|
              values[:time] + expire  < Time.now
            end
          end
        end

      end

      attr_reader :invalid_uris, :invalid_resources
      attr_reader :not_include_update_info_resources

      def initialize()
        @items = []
        @invalid_uris = []
        @invalid_resources = []
        @not_include_update_info_resources = []
        @mutex = Mutex.new
      end

      def parse(uri_str, charset, name=nil, expire=nil)
        begin
          uri = URI.parse(uri_str)
          expire ||= EXPIRE

          raise URI::InvalidURIError unless uri.is_a?(URI::HTTP)

          parsed = false
          need_update = nil

          @@mutex.synchronize do
            need_update = !@@cache.has_key?(uri_str) ||
              ((@@cache[uri_str][:time] + expire) < Time.now)
          end

          if need_update
            if uri.host
              STDERR.puts "updating... #{uri_str}"
              source = get_rss_source(uri, name)
              parsed = update_cache(uri_str, charset, name, source)
            else
              STDERR.puts "not update: #{uri_str}"
            end
          end

          if !parsed and (@@cache[uri_str][:items] || []).empty?
            @mutex.synchronize do
              @not_include_update_info_resources << [uri_str, name]
            end
          end

        rescue URI::InvalidURIError
          STDERR.puts "invalid URI: #{uri_str}"
          cache_invalid_uri(uri_str, name)
          @mutex.synchronize do
            @invalid_uris << [uri_str, name]
          end
        rescue InvalidResourceError, ::RSS::Error
          STDERR.puts "invalid resource: #{uri_str}: #{$!.message}(#{$!.class})"
          cache_invalid_uri(uri_str, name)
          @mutex.synchronize do
            @invalid_resources << [uri_str, name]
          end
        end
      end

      def parallel_parse(args)
        threads = []
        args.each do |uri, charset, name, expire|
          threads << Thread.new {parse(uri, charset, name, expire)}
        end
        threads.each {|t| t.join}
      end
      
      def recent_changes
        has_update_info_values = []
        used_channel = {}
        @@mutex.synchronize do
          @@cache.each do |uri, v|
            channel = v[:channel]
            next if channel.nil?
            name = v[:name]
            image = v[:image]
            v[:items].each do |item|
              next if item.dc_date.nil?
              has_update_info_values << [uri, channel, image, item, name]
            end
          end
        end
        has_update_info_values.sort_by do |_, _, _, item, _|
          item.dc_date
        end.reverse
      end

      def each
        @@mutex.synchronize do
          @@cache.each do |uri, value|
            next if value[:channel].nil?
            yield(uri, value[:channel], value[:image],
                  value[:items], value[:name], value[:time])
          end
        end
      end

      def items(uri)
        begin
          @@mutex.synchronize do
            @@cache[uri][:items] || []
          end
        rescue NameError
          []
        end
      end

      def [](uri)
        @@mutex.synchronize do
          @@cache[uri]
        end
      end

      private
      def cache_invalid_uri(uri, name)
        @@mutex.synchronize do
          @@cache[uri] = {
            :time => Time.now,
            :name => name,
            :channel => nil,
            :items => [],
            :image => nil,
          }
        end
      end

      def get_rss_source(uri, name)
        rss_source = nil
        begin
          begin
            rss_source = fetch_rss(uri, @@cache[uri.to_s][:time])
          rescue NoMethodError
            STDERR.puts uri.inspect
            STDERR.puts $!.class
            STDERR.puts $!.message
            STDERR.puts $@
            raise InvalidResourceError
          end
        rescue TimeoutError,
        SocketError,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError,
        OpenURI::HTTPError,
        SystemCallError, # for sysread
        EOFError # for sysread
          STDERR.puts("timeout: #{uri}") if $!.is_a?(TimeoutError)
          cache_invalid_uri(uri.to_s, name)
          raise InvalidResourceError
        end
        rss_source
      end

      def fetch_rss(uri, cache_time)
        rss = nil
        begin
          uri.open(http_header(cache_time)) do |f|
            case f.status.first
            when "200"
              rss = f.read
              STDERR.puts "Got RSS of #{uri}"
            else
              raise InvalidResourceError
            end
          end
        rescue OpenURI::HTTPError
          if $!.io.status.first == "304"
            # not modified
            STDERR.puts "#{uri} does not modified"
          else
            raise InvalidResourceError
          end
        end
        rss
      end

      def http_header(cache_time)
        header = HTTP_HEADER.dup
        if cache_time.respond_to?(:rfc2822)
          header["If-Modified-Since"] = cache_time.rfc2822
        end
        header
      end

      def update_cache(uri, charset, name, source)
        if source.nil? and @@cache[uri]
          @@mutex.synchronize do
            @@cache[uri][:time] = Time.now
          end
          return false
        end
        
        rss = parse_rss(uri, name, source)

        begin
          rss.output_encoding = charset
        rescue ::RSS::UnknownConvertMethod
        end
        @@mutex.synchronize do 
          @@cache[uri] = {
            :time => Time.now,
            :name => name,
            :channel => rss.channel,
            :items => [],
          }
          @@cache[uri][:image] = rss.image
        end
        
        unless handle_items(uri, rss.items, !rss.channel.dc_date.nil?)
          @mutex.synchronize do
            @not_include_update_info_resources << [uri, name]
          end
        end
        
        true
      end

      def parse_rss(uri, name, source)
        rss = nil
        begin
          rss = ::RSS::Parser.parse(source, true)
        rescue ::RSS::InvalidRSSError
          STDERR.puts "#{uri} is invalid RSS: [#{$!.class}] #{$!.message}"
          rss = ::RSS::Parser.parse(source, false)
          @mutex.synchronize do
            @invalid_resources << [uri, name]
          end
        end

        raise ::RSS::Error if rss.nil?
        rss = rss.to_rss("1.0") do |maker|
          maker.channel.about ||= maker.channel.link
          maker.channel.description ||= "No description"
          maker.items.each do |item|
            item.title ||= "No title"
            item.link ||= "No link"
            item.date ||= maker.channel.date
          end
        end
        raise ::RSS::Error if rss.nil? or rss.channel.nil?
        rss
      end

      def add_content_reader(target)
        class << target
          def content
            if respond_to?(:content_encoded) and content_encoded
              content_encoded
            elsif description
              h(description)
            else
              nil
            end
          rescue ::RSS::ConversionError
            h($!.string)
          end
        end
      end

      def handle_items(uri, items, have_update_info)
        items.delete_if do |item|
          item.link.to_s =~ /\A\s*\z/
        end

        items.each do |item|
          next if /\A\s*\z/ =~ item.title.to_s
          @@mutex.synchronize do
            add_content_reader(item)
            have_update_info = true if item.dc_date
            @@cache[uri][:items] << item
          end
        end

        have_update_info
      end
    end
  end
end
