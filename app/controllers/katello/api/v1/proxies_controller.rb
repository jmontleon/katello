#
# Copyright 2013 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

module Katello
class Api::V1::ProxiesController < Api::V1::ApiController
  before_filter :proxy_request_path, :proxy_request_body
  before_filter :authorize

  # TODO: break up method
  # rubocop:disable MethodLength
  def rules

    proxy_test = lambda do
      route, _, params = Engine.routes.router.recognize(request) do |rte, match, parameters|
        break rte, match, parameters if rte.name
      end

      # route names are defined in routes.rb (:as => :name)
      case route.name
      when "api_proxy_consumer_deletionrecord_delete_path"
        if !User.consumer?
          consumer_gone = false
          begin
            Resources::Candlepin::Consumer.get params[:id] # check with candlepin if system is Gone, raises RestClient::Gone
                                                           # a 200 means the system exists. the deletion record wont exist, but its
                                                           # not a permissions error
          rescue RestClient::Gone
            # the correct response is a 410, since the system has been deleted
            consumer_gone = true
          end
        end
        consumer_gone && (User.consumer? || Organization.all_editable?)
      when "api_proxy_owner_pools_path"
        find_optional_organization
        if params[:consumer]
          (User.consumer? || @organization.readable?) && current_user.uuid == params[:consumer]
        else
          (User.consumer? || @organization.readable?)
        end
      when "api_proxy_owner_servicelevels_path"
        find_optional_organization
        (User.consumer? || @organization.readable?)
      when "api_proxy_consumer_certificates_path", "api_proxy_consumer_releases_path", "api_proxy_certificate_serials_path",
          "api_proxy_consumer_entitlements_path", "api_proxy_consumer_entitlements_post_path", "api_proxy_consumer_entitlements_delete_path",
          "api_proxy_consumer_dryrun_path", "api_proxy_consumer_owners_path", "api_proxy_consumer_compliance_path"
        User.consumer? && current_user.uuid == params[:id]
      when "api_proxy_consumer_certificates_delete_path"
        User.consumer? && current_user.uuid == params[:consumer_id]
      when "api_proxy_pools_path"
        User.consumer? && current_user.uuid == params[:consumer]
      when "api_proxy_entitlements_path"
        User.consumer? # query is restricted in Candlepin
      when "api_proxy_subscriptions_post_path"
        User.consumer? && current_user.uuid == params[:consumer_uuid]
      when "api_proxy_deleted_consumers_path"
        current_user.has_superadmin_role?
      else
        Rails.logger.warn "Unknown proxy route #{request.method} #{request.fullpath}, access denied"
        # give the proxy route name using :as parameter and implement rule check here
        false
      end
    end
    {
        :get    => proxy_test,
        :post   => proxy_test,
        :put    => proxy_test,
        :delete => proxy_test
    }
  end

  rescue_from RestClient::Exception do |e|
    Rails.logger.error pp_exception(e)
    if request_from_katello_cli?
      render :json => { :errors => [e.http_body] }, :status => e.http_code
    else
      render :text => e.http_body, :status => e.http_code
    end
  end

  def proxy_request_path
    @request_path = drop_api_namespace(@_request.fullpath)
  end

  def proxy_request_body
    @request_body = @_request.body
  end

  def drop_api_namespace(original_request_path)
    prefix = "#{Katello.config.url_prefix}/api"
    original_request_path.gsub(prefix, '')
  end

end
end
