# encoding: utf-8
class Cms::Admin::SitesController < Cms::Controller::Admin::Base
  include Sys::Controller::Scaffold::Base

  def pre_dispatch
    return error_auth unless Core.user.has_auth?(:manager)
  end

  def index
    @items = Cms::Site
             .all
             .order(:id)
             .paginate(page: params[:page], per_page: params[:limit])

    _index @items
  end

  def show
    @item = Cms::Site.find(params[:id])
    return error_auth unless @item.readable?

    _show @item
  end

  def new
    @item = Cms::Site.new(state: 'public')
  end

  def create
    @item = Cms::Site.new(site_params)
    @item.state = 'public'
    _create @item do
      make_concept(@item)
      make_node(@item)
      ::Storage.mkdir_p(@item.public_path)
    end
  end

  def update
    @item = Cms::Site.find(params[:id])
    @item.attributes = site_params
    _update @item do
      make_node(@item)
    end
  end

  def destroy
    @item = Cms::Site.find(params[:id])
    _destroy(@item) do
      cookies.delete(:cms_site)
    end
  end

  protected

  def make_concept(item)
    concept = Cms::Concept.new(parent_id: 0,
                               site_id: item.id,
                               state: 'public',
                               level_no: 1,
                               sort_no: 1,
                               name: item.name)
    concept.save
  end

  def make_node(item)
    if node = item.root_node
      if node.title != item.name
        node.title = item.name
        node.save
      end
      return true
    end

    concept = Cms::Concept.find_by(site_id: item.id)

    node = Cms::Node.new(site_id: item.id,
                         state: 'public',
                         published_at: Core.now,
                         parent_id: 0,
                         route_id: 0,
                         model: 'Cms::Directory',
                         directory: 1,
                         name: '/',
                         title: item.name)
    node.save(validate: false)

    top = Cms::Node.new(site_id: item.id,
                        state: 'public',
                        published_at: Core.now,
                        parent_id: node.id,
                        route_id: node.id,
                        concept_id: concept.id,
                        model: 'Cms::Page',
                        directory: 0,
                        name: 'index.html',
                        title: item.name)
    top.save(validate: false)

    item.node_id = node.id
    item.save
  end

  private

  def site_params
    params.require(:item).permit(
      :name, :full_uri, :alias_full_uri, :mobile_full_uri, :admin_full_uri,
      :related_site, :google_map_api_key, in_creator: [:group_id, :user_id])
  end
end
