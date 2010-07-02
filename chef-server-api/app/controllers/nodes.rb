#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Christopher Brown (<cb@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef' / 'node'

class Nodes < Application
  
  provides :json
  
  before :authenticate_every 
  before :admin_or_requesting_node, :only => [ :update, :destroy, :cookbooks ]
  
  def index
    @node_list = Chef::Node.cdb_list 
    display(@node_list.inject({}) do |r,n|
      r[n] = absolute_url(:node, n); r
    end)
  end

  def show
    begin
      @node = Chef::Node.cdb_load(params[:id])
    rescue Chef::Exceptions::CouchDBNotFound => e
      raise NotFound, "Cannot load node #{params[:id]}"
    end
    @node.couchdb_rev = nil
    display @node
  end

  def create
    @node = params["inflated_object"]
    begin
      Chef::Node.cdb_load(@node.name) 
      raise Conflict, "Node already exists"
    rescue Chef::Exceptions::CouchDBNotFound
    end
    self.status = 201
    @node.cdb_save
    display({ :uri => absolute_url(:node, @node.name) })
  end

  def update
    begin
      @node = Chef::Node.cdb_load(params[:id])
    rescue Chef::Exceptions::CouchDBNotFound => e
      raise NotFound, "Cannot load node #{params[:id]}"
    end

    @node.update_from!(params['inflated_object'])
    @node.cdb_save
    @node.couchdb_rev = nil
    display(@node)
  end

  def destroy
    begin
      @node = Chef::Node.cdb_load(params[:id])
    rescue Chef::Exceptions::CouchDBNotFound => e 
      raise NotFound, "Cannot load node #{params[:id]}"
    end
    @node.cdb_destroy
    @node.couchdb_rev = nil
    display @node
  end

  def cookbooks
    begin
      @node = Chef::Node.cdb_load(params[:id])
    rescue Chef::Exceptions::CouchDBNotFound => e 
      raise NotFound, "Cannot load node #{params[:id]}"
    end

    display(load_all_files)
  end

  private

  def load_all_files
    all_cookbooks = Chef::Environment.cdb_load_filtered_cookbook_versions(@node.chef_environment)

    included_cookbooks = cookbooks_for_node(all_cookbooks)
    nodes_cookbooks = Hash.new
    included_cookbooks.each do |cookbook_name, cookbook|
      next unless cookbook

      nodes_cookbooks[cookbook_name.to_s] = cookbook.generate_manifest_with_urls{|opts| absolute_url(:cookbook_file, opts) }
    end

    nodes_cookbooks
  end

  # returns name -> CookbookVersion for all cookbooks included on the given node.
  def cookbooks_for_node(all_cookbooks)
    # expand returns a RunListExpansion which contains recipes, default and override attrs [cb]
    items = @node.run_list.expand('couchdb').run_list_items

    # walk run list and accumulate included dependencies
    items.inject({}) do |included_cookbooks, rli|
      next unless rli.recipe?
      expand_cookbook_deps(included_cookbooks, all_cookbooks, rli)
      included_cookbooks
    end
  end

  # Accumulates transitive cookbook dependencies no more than once in included_cookbooks
  #   included_cookbooks == hash of name -> CookbookVersion, which is used for returning
  #                         result as well as for tracking which cookbooks we've already
  #                         recursed into
  #   all_cookbooks    == hash of name -> CookbookVersion, all cookbooks available
  #   run_list_items   == name of cookbook to include
  def expand_cookbook_deps(included_cookbooks, all_cookbooks, run_list_item)
    # determine the run list item's parent cookbook, which might be run_list_item in the default case
    version = "latest"
    if run_list_item.kind_of? Chef::RunList::RunListItem
      cookbook_name = (run_list_item.name[/^(.+)::/, 1] || run_list_item.name)
      version = run_list_item.version unless run_list_item.version.nil?
    else
      cookbook_name = (run_list_item[/^(.+)::/, 1] || run_list_item.to_s)
    end

    Chef::Log.debug("Node requires #{cookbook_name} at #{version}")
    # include its dependencies
    included_cookbooks[cookbook_name] = Chef::CookbookVersion.cdb_load(cookbook_name, version)
    if !included_cookbooks[cookbook_name]
      return false
      # NOTE [dan/cw] We don't think changing this to an exception breaks stuff.
      # Chef::Log.warn "#{__FILE__}:#{__LINE__}: in expand_cookbook_deps, cookbook/role #{cookbook_name} could not be found, ignoring it in cookbook expansion"
      # return included_cookbooks
    end

    # TODO: 5/27/2010 cw: implement dep_version_constraints according to
    # http://wiki.opscode.com/display/chef/Metadata#Metadata-depends,
    included_cookbooks[cookbook_name].metadata.dependencies.each do |depname, dep_version_constraints|
      # recursively expand dependencies into included_cookbooks unless
      # we've already done it
      unless included_cookbooks[depname]
        unless expand_cookbook_deps(included_cookbooks, all_cookbooks, depname)
          raise PreconditionFailed, "cookbook #{cookbook_name} depends on cookbook #{depname}, but #{depname} does not exist"

        end
      end
    end
    true
  end

end

