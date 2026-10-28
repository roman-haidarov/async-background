# frozen_string_literal: true

require 'cgi'
require 'digest'

module Async
  module Background
    module Web
      module Assets
        ASSET_DIR = File.join(__dir__, 'assets').freeze
        CSS = File.read(File.join(ASSET_DIR, 'app.css')).freeze
        JS = File.read(File.join(ASSET_DIR, 'app.js')).freeze
        INDEX_HTML = File.read(File.join(ASSET_DIR, 'index.html')).freeze

        module_function

        def asset_version
          @asset_version ||= Digest::SHA256.hexdigest("#{JS}\0#{CSS}")[0, 12]
        end

        def render_index(config)
          base = config.mount_path.to_s.sub(%r{/\z}, '')
          format(
            INDEX_HTML,
            title: CGI.escapeHTML(config.title.to_s),
            base: CGI.escapeHTML(base),
            asset_version: asset_version
          )
        end
      end
    end
  end
end
