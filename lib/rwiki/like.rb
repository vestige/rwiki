# -*- indent-tabs-mode: nil -*-

require 'rwiki/rw-lib'
require 'rwiki/gettext'
require 'rwiki/pagemodule'
require 'rwiki/navi'

module RWiki
  
  N_("like")

  Version.regist('rwiki/like', '2003-02-09')

  class LikeFormat < NaviFormat
  @rhtml = { :view => ERBLoader.new('view(pg)', 'like.rhtml')}
    reload_rhtml
    
    def navi_view(pg, title, referer)
      params = {
        'key' => referer.name,
        'navi' => pg.name,
      }
      %Q[<span class="navi">[<a href="#{ ref_name(pg.name, params) }">#{ h title }</a>]</span>]
    end
  end
  
  install_page_module('like', LikeFormat, _('like'))
end