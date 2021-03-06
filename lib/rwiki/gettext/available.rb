# -*- indent-tabs-mode: nil -*-

require 'gettext'
require "thread"

module GetText
  class TextDomain
    def locale
      %r!/([^/]+)/LC_MESSAGES/! =~ @search_files.last.to_s
      $1
    end
  end
end

module RWiki
  module GetTextMixin

    class << self
      def make_gettext(locale=nil, charset=nil)
        args = ["rwiki", nil]
        if ::GetText::TextDomain.instance_methods.include?("set_charset")
          locale ||= Locale.get
          args.concat([locale, charset])
        else
          if locale
            locale = Locale::Object.new(locale)
          else
            locale = Locale.get
          end
          charset ||= ENV["OUTPUT_CHARSET"]
          locale.charset = charset if charset
          args << locale
        end
        ::GetText::TextDomain.new(*args)
      end
    end

    @@default_gettext = make_gettext
    @@gettexts = {}
    @@mutex = Mutex.new

    def init_gettext(locales, available_locales)
      @gettext = @@default_gettext
      @@mutex.synchronize do
        locales.each do |locale|
          if available_locales.include?(locale)
            if @@gettexts.has_key?(locale)
              @gettext = @@gettexts[locale]
            else
              @gettext = GetTextMixin.make_gettext(locale)
              @@gettexts[locale] = @gettext
            end
            return
          end
        end
      end
    end

    def locale
      @gettext.locale
    end

    def _(msgid)
      @gettext.gettext(msgid)
    end

    def N_(msgid)
      msgid
    end

    def n_(msgid, msgid_plural, n)
      @gettext.ngettext(msgid, msgid_plural, n)
    end

    def s_(msgid, div='|')
      msg = @gettext.gettext(msgid) || msgid
      if msg == msgid and index = msg.rindex(div)
        msg = msg[(index + 1)..-1]
      end
      msg
    end
  end
end
