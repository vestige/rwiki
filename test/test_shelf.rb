require 'test/unit'

module RWiki
  ADDRESS = 'Masatoshi SEKI'
  MAILTO = 'mailto:m_seki@mva.biglobe.ne.jp'
  CSS = nil
  LANG = nil
  CHARSET = nil
  DB_DIR = 'rd'
  TOP_NAME = 'top'
  TITLE = 'RWiki'
  DRB_URI = 'druby://:8470'
end

require 'rwiki/rwiki'
require 'rwiki/db/mock'
require 'rwiki/shelf/shelf'

class TestShelf < Test::Unit::TestCase
  def setup
    @db = RWiki::DB::Mock.new
    RWiki::BookConfig.default.db = @db
    RWiki::Book.section_list.clear
    @shelf_section = RWiki::Shelf::AsinSection.new(nil)
    RWiki::Book.section_list.push(@shelf_section)
    @book = RWiki::Book.new
  end

  def teardown
  end

  def test_core
    top = @book['top']
    assert_equal(nil, top.src)
    top.src = "= Top\n"
    assert_equal("= Top\n", top.src)
  end

  def test_asin
    druby = @book['asin:4756139612']
    assert_equal(@shelf_section, druby.section)
    prop = druby.prop(:shelf)
    assert(prop != nil)
    assert_equal('4756139612', prop[:asin])
    assert_equal('2001/10', prop[:release_date])
  end
end