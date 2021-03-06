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
class Product < ActiveRecord::Base
  self.include_root_in_json = false

  include Glue::ElasticSearch::Product if Katello.config.use_elasticsearch
  include Glue::Candlepin::Product if Katello.config.use_cp
  include Glue::Pulp::Repos if Katello.config.use_pulp
  include Glue if Katello.config.use_cp || Katello.config.use_pulp

  include Katello::Authorization::Product
  include AsyncOrchestration

  include Ext::LabelFromName

  attr_accessible :name, :label, :description, :provider_id, :provider,
                  :gpg_key_id, :gpg_key, :cp_id

  has_many :marketing_engineering_products, :class_name => "Katello::MarketingEngineeringProduct",
           :foreign_key => :engineering_product_id, :dependent => :destroy
  has_many :marketing_products, :through => :marketing_engineering_products

  belongs_to :provider, :inverse_of => :products
  belongs_to :sync_plan, :inverse_of => :products
  belongs_to :gpg_key, :inverse_of => :products
  has_many :content_view_definition_products, :class_name => "Katello::ContentViewDefinitionProduct",
           :dependent => :destroy
  has_many :content_view_definitions, :through => :content_view_definition_products
  has_many :repositories, :class_name => "Katello::Repository", :dependent => :destroy

  validates :provider_id, :presence => true
  validates_with Validators::KatelloNameFormatValidator, :attributes => :name
  validates_with Validators::KatelloLabelFormatValidator, :attributes => :label
  validates_with Validators::KatelloDescriptionFormatValidator, :attributes => :description
  validate  :validate_unique_name

  # scope
  def self.with_repos_only(env)
    with_repos(env, false)
  end

  # scope
  def self.with_enabled_repos_only(env)
    with_repos(env, true)
  end

  def self.find_by_cp_id(cp_id, organization = nil)
    query = self.where(:cp_id => cp_id).scoped(:readonly => false)
    query = query.in_org(organization) if organization
    query.engineering.first || query.marketing.first
  end

  def self.in_org(organization)
    self.joins(:provider).where("#{Katello::Provider.table_name}.organization_id" => organization.id)
  end

  scope :engineering, where(:type => "Katello::Product")
  scope :marketing, where(:type => "Katello::MarketingProduct")

  before_create :assign_unique_label

  def initialize(attrs = nil, options = {})

    unless attrs.nil?
      attrs = attrs.with_indifferent_access

      #rename "id" to "cp_id" (activerecord and candlepin variable name conflict)
      if attrs.key?(:id)
        if !attrs.key?(:cp_id)
          attrs[:cp_id] = attrs[:id]
        end
        attrs.delete(:id)
      end

      # ugh. hack-ish. otherwise we have to modify code every time things change on cp side
      attrs = attrs.reject do |k, v|
        !self.class.column_defaults.keys.member?(k.to_s) && (!respond_to?(:"#{k.to_s}=") rescue true)
      end
    end

    super
  end

  def repos(env, include_disabled = false, content_view = nil, include_feedless = true)
    if content_view.nil?
      if !env.library?
        fail "No content view specified for the repos call in a " +
                        "Non library environment #{env.inspect}"
      else
        content_view = env.default_content_view
      end
    end

    # cache repos so we can cache lazy_accessors
    @repo_cache ||= {}
    @repo_cache[env.id] ||= content_view.repos_in_product(env, self)

    repositories = @repo_cache[env.id]
    repositories = repositories.enabled if !include_disabled
    repositories = repositories.has_feed if !include_feedless
    repositories
  end

  def enabled?
    !self.provider.redhat_provider? || self.repositories.enabled.present?
  end

  def organization
    provider.organization
  end

  def library
    organization.library
  end

  def plan_name
    return sync_plan.name if sync_plan
    N_('None')
  end

  # rubocop:disable SymbolName
  def serializable_hash(options = {})
    options = {} if options.nil?

    hash = super(options.merge(:except => [:cp_id, :id]))
    hash = hash.merge(:productContent => self.productContent,
                      :multiplier => self.multiplier,
                      :attributes => self.attrs,
                      :id => self.cp_id)
    if Katello.config.katello?
      hash = hash.merge(
        :sync_plan_name => self.sync_plan ? self.sync_plan.name : nil,
        :sync_state => self.sync_state,
        :last_sync => self.last_sync
      )
    end
    hash
  end

  def redhat?
    provider.redhat_provider?
  end

  def custom?
    !(redhat?)
  end

  def gpg_key_name=(name)
    if name.blank?
      self.gpg_key = nil
    else
      self.gpg_key = GpgKey.readable(organization).find_by_name!(name)
    end
  end

  # TODO: this should be a part of product update orchestration
  def reset_repo_gpgs!
    repositories.each do |repo|
      repo.update_attributes!(:gpg_key => self.gpg_key)
    end
  end

  scope :all_in_org, lambda{|org| Product.joins(:provider).where("#{Katello::Provider.table_name}.organization_id = ?", org.id)}

  scope :repositories_cdn_import_failed, where(:cdn_import_success => false)

  def assign_unique_label
    self.label = Util::Model.labelize(self.name) if self.label.blank?

    # if the object label is already being used in this org, append the id to make it unique
    if Product.all_in_org(self.organization).where("#{Katello::Product.table_name}.label = ?", self.label).count > 0
      self.label = self.label + "_" + self.cp_id unless self.cp_id.blank?
    end
  end

  def as_json(*args)
    ret = super
    ret["gpg_key_name"] = gpg_key ? gpg_key.name : ""
    ret["marketing_product"] = self.is_a? MarketingProduct
    ret
  end

  def delete_repos(repos)
    repos.each{|repo| repo.destroy}
  end

  def delete_from_env(from_env)
    @orchestration_for = :delete
    delete_repos(repos(from_env))
    if from_env.products.include? self
      self.environments.delete(from_env)
    end
    save!
  end

  def environments_for_view(view)
    versions = view.versions.select{|version| version.products.include?(self)}
    versions.collect{|v|v.environments}.flatten
  end

  def environments
    KTEnvironment.where(:organization_id => organization.id).
      where("library = ? OR id IN (?)", true, repositories.map(&:environment_id))
  end

  def syncable_content?
    repositories.any?(&:feed?)
  end

  protected

  def self.with_repos(env, enabled_only)
    query = Repository.in_environment(env.id).select(:product_id)
    query = query.enabled if enabled_only
    joins(:provider).where("#{Katello::Provider.table_name}.organization_id" => env.organization).
        where("(#{Katello::Provider.table_name}.provider_type ='#{Provider::CUSTOM}') OR \
              (#{Katello::Provider.table_name}.provider_type ='#{Provider::REDHAT}' AND \
              #{Katello::Product.table_name}.id in (#{query.to_sql}))")
  end

  def validate_unique_name
    if self.provider && !self.provider.redhat_provider? && self.name_changed?
      if Product.in_org(self.provider.organization).where(:name => self.name).exists?
        self.errors[:name] << _("Product with name %s already exists in this organization.") % self.name
      end
    end
  end

end
end
