require 'active_support'
require 'action_pack'
require 'action_view'

module Rubaidh # :nodoc:
  # This module gets mixed in to ActionController::Base
  module GoogleAnalyticsMixin
    # The javascript code to enable Google Analytics on the current page.
    # Normally you won't need to call this directly; the +add_google_analytics_code+
    # after filter will insert it for you.
    def google_analytics_code
      GoogleAnalytics.google_analytics_code(request.ssl?) if GoogleAnalytics.enabled?(request.format)
    end
    
    # An after_filter to automatically add the analytics code.
    # If you intend to use the link_to_tracked view helpers, you need to set Rubaidh::GoogleAnalytics.defer_load = false
    # to load the code at the top of the page
    # (see http://www.google.com/support/googleanalytics/bin/answer.py?answer=55527&topic=11006)
    
    def add_google_analytics_code
      # Rails (2.3.x + rails_xss) or Rails 3 plugin support: can't use sub!
      if "".respond_to?(:html_safe) && response.body.respond_to?(:sub)
        body = if GoogleAnalytics.asynchronous_mode
          response.body.sub /(<\/[hH][eE][aA][dD][^>]*>)/, "#{google_analytics_code}\\1" 
        elsif GoogleAnalytics.defer_load
          response.body.sub /<\/[bB][oO][dD][yY]>/, "#{google_analytics_code}</body>"
        else
          response.body.sub /(<[bB][oO][dD][yY][^>]*>)/, "\\1#{google_analytics_code}"
        end
        response.body = body.html_safe
      elsif response.body.respond_to?(:sub!)
        if GoogleAnalytics.asynchronous_mode
          response.body.sub! /(<\/[hH][eE][aA][dD][^>]*>)/, "#{google_analytics_code}\\1" 
        elsif GoogleAnalytics.defer_load
          response.body.sub! /<\/[bB][oO][dD][yY]>/, "#{google_analytics_code}</body>"
        else
          response.body.sub! /(<[bB][oO][dD][yY][^>]*>)/, "\\1#{google_analytics_code}"
        end
      end
    end
  end
  
  class GoogleAnalyticsConfigurationError < StandardError; end

  # The core functionality to connect a Rails application
  # to a Google Analytics installation.
  class GoogleAnalytics
  
    @@tracker_id = nil
    ##
    # :singleton-method:
    # Specify the Google Analytics ID for this web site. This can be found
    # as the value of +_getTracker+ if you are using the new (ga.js) tracking
    # code, or the value of +_uacct+ if you are using the old (urchin.js)
    # tracking code.
    cattr_accessor :tracker_id  

    @@domain_name = nil
    ##
    # :singleton-method:
    # Specify a different domain name from the default. You'll want to use
    # this if you have several subdomains that you want to combine into
    # one report. See the Google Analytics documentation for more
    # information.
    cattr_accessor :domain_name

    @@legacy_mode = false
    ##
    # :singleton-method:
    # Specify whether the legacy Google Analytics code should be used. By
    # default, the new Google Analytics code is used.
    cattr_accessor :legacy_mode

    @@asynchronous_mode = false
    ##
    # :singleton-method:
    # Specify whether the new Asynchronous Google Analytics code should be used.
    # By default, the synchronous Google Analytics code is used.
    # For more information:
    # http://code.google.com/apis/analytics/docs/tracking/asyncTracking.html
    cattr_accessor :asynchronous_mode
    
    @@analytics_url = 'http://www.google-analytics.com/urchin.js'
    ##
    # :singleton-method:
    # The URL that analytics information is sent to. This defaults to the
    # standard Google Analytics URL, and you're unlikely to need to change it.
    # This has no effect unless you're in legacy mode.
    cattr_accessor :analytics_url

    @@analytics_ssl_url = 'https://ssl.google-analytics.com/urchin.js'
    ##
    # :singleton-method:
    # The URL that analytics information is sent to when using SSL. This defaults to the
    # standard Google Analytics URL, and you're unlikely to need to change it.
    # This has no effect unless you're in legacy mode.
    cattr_accessor :analytics_ssl_url

    @@environments = ['production']
    ##
    # :singleton-method:
    # The environments in which to enable the Google Analytics code. Defaults
    # to 'production' only. Supply an array of environment names to change this.
    cattr_accessor :environments
    
    @@formats = [:html, :all]
    ##
    # :singleton-method:
    # The request formats where tracking code should be added. Defaults to +[:html, :all]+. The entry for
    # +:all+ is necessary to make Google recognize that tracking is installed on a
    # site; it is not the same as responding to all requests. Supply an array
    # of formats to change this.
    cattr_accessor :formats

    @@defer_load = true
    ##
    # :singleton-method:
    # Set this to true (the default) if you want to load the Analytics javascript at 
    # the bottom of page. Set this to false if you want to load the Analytics 
    # javascript at the top of the page. The page will render faster if you set this to
    # true, but that will break the linking functions in Rubaidh::GoogleAnalyticsViewHelper.
    cattr_accessor :defer_load
    
    @@local_javascript = false
    ##
    # :singleton-method:
    # Set this to true to use a local copy of the ga.js (or urchin.js) file.
    # This gives you the added benefit of serving the JS directly from your
    # server, which in case of a big geographical difference between your server
    # and Google's can speed things up for your visitors. Use the 
    # 'google_analytics:update' rake task to update the local JS copies.
    cattr_accessor :local_javascript
    
    ##
    # :singleton-method:
    # Set this to override the initialized domain name for a single render. Useful
    # when you're serving to multiple hosts from a single codebase. Typically you'd 
    # set up a before filter in the appropriate controller:
    #    before_filter :override_domain_name
    #    def override_domain_name
    #      Rubaidh::GoogleAnalytics.override_domain_name  = 'foo.com'
    #   end
    cattr_accessor :override_domain_name
    
    ##
    # :singleton-method:
    # Set this to override the initialized tracker ID for a single render. Useful
    # when you're serving to multiple hosts from a single codebase. Typically you'd 
    # set up a before filter in the appropriate controller:
    #    before_filter :override_tracker_id
    #    def override_tracker_id
    #      Rubaidh::GoogleAnalytics.override_tracker_id  = 'UA-123456-7'
    #   end
    cattr_accessor :override_tracker_id
    
    ##
    # :singleton-method:
    # Set this to override the automatically generated path to the page in the
    # Google Analytics reports for a single render. Typically you'd set this up on an 
    # action-by-action basis:
    #    def show
    #      Rubaidh::GoogleAnalytics.override_trackpageview = "path_to_report"
    #      ...
    cattr_accessor :override_trackpageview
    
    # Return true if the Google Analytics system is enabled and configured
    # correctly for the specified format
    def self.enabled?(format)
      raise Rubaidh::GoogleAnalyticsConfigurationError if tracker_id.blank? || analytics_url.blank?
      environments.include?(Rails.env) && !format.blank? && formats.include?(format.to_sym)
    end
    
    # Construct the javascript code to be inserted on the calling page. The +ssl+
    # parameter can be used to force the SSL version of the code in legacy mode only.
    def self.google_analytics_code(ssl = false)
      return asynchronous_google_analytics_code if asynchronous_mode
      return legacy_google_analytics_code(ssl) if legacy_mode

      extra_code = domain_name.blank? ? nil : "pageTracker._setDomainName(\"#{domain_name}\");"
      if !override_domain_name.blank?
        extra_code = "pageTracker._setDomainName(\"#{override_domain_name}\");"
        self.override_domain_name = nil
      end
      
      tag_helper = JavaScriptTagHelper.new
      
      code = if local_javascript
        tag_helper.javascript_include_tag LocalAssetTagHelper.new.javascript_path('ga.js')
      else
        tag_helper.javascript_tag %Q|
          var gaJsHost = (("https:" == document.location.protocol) ? "https://ssl." : "http://www.");
          document.write(unescape("%3Cscript src='" + gaJsHost + "google-analytics.com/ga.js' type='text/javascript'%3E%3C/script%3E"));
          </script>
        |
      end
      
      code << tag_helper.javascript_tag(%Q|
        <!--//--><![CDATA[//><!--
        try {
        var pageTracker = _gat._getTracker('#{request_tracker_id}');
        #{extra_code}
        pageTracker._initData();
        pageTracker._trackPageview(#{request_tracked_path});
        } catch(err) {}
        function recordOutboundLink(link, category, action, opt_label, opt_value) {
          try {
            pageTracker._trackEvent(category, action, opt_label, opt_value);
            setTimeout('document.location = "' + link.href + '"', 100)
          }catch(err){}
        }
        function recordOutboundLinkNewWindow(link, category, action, opt_label, opt_value) {
          try {
            h = window.open(link.href);
            setTimeout(function() {
              pageTracker._trackEvent(category, action, opt_label, opt_value);
            }, 1000);
          }catch(err){}
        }
        //--><!]]>
      |)
    end

    # Construct the legacy version of the Google Analytics code. The +ssl+
    # parameter specifies whether or not to return the SSL version of the code.
    def self.legacy_google_analytics_code(ssl = false)
      extra_code = domain_name.blank? ? nil : "_udn = \"#{domain_name}\";"
      if !override_domain_name.blank?
        extra_code = "_udn = \"#{override_domain_name}\";"
        self.override_domain_name = nil
      end
      
      tag_helper = JavaScriptTagHelper.new
      code = tag_helper.javascript_include_tag(legacy_analytics_js_url(ssl))
      code << tag_helper.javascript_tag(%Q|
        _uacct = "#{request_tracker_id}";
        #{extra_code}
        urchinTracker(#{request_tracked_path});
      |)
    end

    # Construct the new asynchronous version of the Google Analytics code.
    def self.asynchronous_google_analytics_code
      JavaScriptTagHelper.new.javascript_tag %Q~
        function recordOutboundLink(link, category, action, opt_label, opt_value) {
          _gaq.push(['_trackEvent', category, action, opt_label, opt_value]);
          setTimeout('document.location = "' + link.href + '"', 100);
        }
        function recordOutboundLinkNewWindow(link, category, action, opt_label, opt_value) {
          try {
            h = window.open(link.href);
            setTimeout(function() {
              _gaq.push(['_trackEvent', category, action, opt_label, opt_value]);
            }, 1000);
          }catch(err){}
        }
        var _gaq = _gaq || [];
        _gaq.push(['_setAccount', '#{request_tracker_id}']);
        _gaq.push(['_trackPageview']);

        (function() {
          var ga = document.createElement('script'); ga.type = 'text/javascript'; ga.async = true;
          ga.src = ('https:' == document.location.protocol ? 'https://ssl' : 'http://www') + '.google-analytics.com/ga.js';
          var s = document.getElementsByTagName('script')[0]; s.parentNode.insertBefore(ga, s);
        })();
      ~
    end
    
    # Generate the correct URL for the legacy Analytics JS file
    def self.legacy_analytics_js_url(ssl = false)
      if local_javascript
        LocalAssetTagHelper.new.javascript_path( 'urchin.js' )
      else
        ssl ? analytics_ssl_url : analytics_url
      end
    end

    # Determine the tracker ID for this request
    def self.request_tracker_id
      use_tracker_id = override_tracker_id.blank? ? tracker_id : override_tracker_id
      self.override_tracker_id = nil
      use_tracker_id
    end
    
    # Determine the path to report for this request
    def self.request_tracked_path
      use_tracked_path = override_trackpageview.blank? ? '' : "'#{override_trackpageview}'"
      self.override_trackpageview = nil
      use_tracked_path
    end
    
  end

  class LocalAssetTagHelper # :nodoc:
    # For helping with local javascripts
    include ActionView::Helpers::AssetTagHelper
  end
  
  class JavaScriptTagHelper # :nodoc:
    # For helping with javascript tags
    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::JavaScriptHelper
  end
end
