# -*- indent-tabs-mode: nil -*-

require 'rwiki/rw-lib'
require 'rwiki/gettext'
require 'rwiki/pagemodule'
require 'rwiki/navi'

module RWiki

  Version.regist('rwiki/orphan', '2004-11-23')

  class OrphanFormat < NaviFormat
    @rhtml = { :view => ERBLoader.new('view(pg)', 'orphan.rhtml') }
    reload_rhtml
  end

  install_page_module('orphan', OrphanFormat, s_("navi|orphan"))
end
