# -*- indent-tabs-mode: nil -*-

require 'soap/wsdlDriver'
require 'rwiki/shelf/AmazonSearch.rb'

class AmazonWebService
  def initialize(tag = 'ilikeruby-22')
    @devtag = get_devtag
    @tag = tag
    @amazon = SOAP::WSDLDriverFactory.new(wsdl).createDriver
    @amazon.generate_explicit_type = true
  end
  attr_reader :amazon

  def locale
    nil
  end

  def wsdl
    'http://soap.amazon.com/schemas3/AmazonWebServices.wsdl'
  end

  def asin_search(asin)
    req = AsinRequest.new(asin, @tag, "lite", @devtag)
    req.locale = locale if locale
    @amazon.AsinSearchRequest(req).Details.each do |detail|
      raise('Invalid ASIN') if /^Invalid ASIN/ =~ detail.Status.to_s
      return detail
    end
  end

  def sales_rank(asin)
    req = AsinRequest.new(asin, @tag, "heavy", @devtag)
    req.locale = locale if locale
    @amazon.AsinSearchRequest(req).Details.each do |detail|
      raise('Invalid ASIN') if /^Invalid ASIN/ =~ detail.Status.to_s
      return detail.SalesRank
    end
  end

  def keyword_search(text)
    req = KeywordRequest.new(text, '1', 'book', @tag, "lite", @devtag)
    req.locale = locale if locale
    @amazon.KeywordSearchRequest(req).Details
  end

  def blended_search(text)
    req = BlendedRequest.new(text, @tag, "lite", @devtag)
    req.locale = locale if locale
    @amazon.BlendedSearchRequest(req)
  end

  private
  def get_devtag
    File.open(File.expand_path("~/.amazon_key")) do |fp|
      return fp.read.chomp
    end
  end
end

class AmazonCoJp < AmazonWebService
  def locale
    'jp'
  end

  def wsdl
    'http://soap.amazon.co.jp/schemas3/AmazonWebServices.wsdl'
  end
end
