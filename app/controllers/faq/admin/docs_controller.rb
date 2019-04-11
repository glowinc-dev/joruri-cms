# encoding: utf-8
class Faq::Admin::DocsController < Cms::Controller::Admin::Base
  include Sys::Controller::Scaffold::Base
  include Sys::Controller::Scaffold::Recognition
  include Sys::Controller::Scaffold::Publication
  helper Faq::FormHelper

  def pre_dispatch
    @content = Cms::Content.find(params[:content])
    return error_auth unless @content
    return error_auth unless Core.user.has_priv?(:read, item: @content.concept)
    return redirect_to(request.env['PATH_INFO']) if params[:reset]

    @recognition_type = @content.setting_value(:recognition_type)
  end

  def index
    return index_options if params[:options]
    return user_options if params[:user_options]
    redirect_to faq_edit_docs_path
  end

  def index_options
    @items = Faq::Doc.where(state: 'public', content_id: @content.id)
    docs_table = @items.table

    if params[:exclude]
      @items = @items.where(docs_table[:name].not_eq(params[:exclude]))
    end
    if params[:title] && !params[:title].blank?
      @items = @items.where(docs_table[:title].matches("%#{params[:title]}%"))
    end
    if params[:id] && !params[:id].blank?
      @items = @items.where(docs_table[:id].eq(params[:id]))
    end

    if params[:group_id] || params[:user_id]
      inners = []
      if params[:group_id] && !params[:group_id].blank?
        groups = Sys::Group.arel_table
        inners << :group
      end
      if params[:user_id] && !params[:user_id].blank?
        users = Sys::User.arel_table
        inners << :user
      end
      @items = @items.joins(:creator => inners)

      @items = @items.where(groups[:id].eq(params[:group_id])) if params[:group_id].present?
      @items = @items.where(users[:id].eq(params[:user_id])) if params[:user_id].present?
    end

    @items = @items.order(published_at: :desc, updated_at: :desc)

    @items = @items.map { |item| [view_context.truncate("[#{item.id}] #{item.title}", length: 50), item.id] }
    render html: view_context.options_for_select([nil] + @items), layout: false
  end

  def user_options
    @parent = Sys::Group.find(params[:group_id])
    render 'user_options', layout: false
  end

  def show
    @item = Faq::Doc.find(params[:id])

    @item.recognition.type = @recognition_type if @item.recognition

    _show @item
  end

  def new
    @item = Faq::Doc.new(content_id: @content.id,
                         state: 'recognize',
                         recent_state: 'visible')
    @item.in_inquiry = @item.default_inquiry
    @item.in_recognizer_ids = @content.setting_value(:default_recognizers)

    ## add tmp_id
    unless params[:_tmp]
      return redirect_to url_for(action: :new, _tmp: Util::Sequencer.next_id(:tmp, md5: true))
    end
  end

  def create
    @item = Faq::Doc.new(docs_params)
    @item.content_id = @content.id
    @item.state      = 'draft'
    @item.state      = 'recognize' if params[:commit_recognize]
    @item.state      = 'public'    if params[:commit_public]

    ## convert sys urls
    unid = params[:_tmp] || @item.unid
    @item.body = @item.body.gsub(::File.join(Core.site.full_uri, faq_preview_doc_file_path(parent: unid)), '.')

    _create @item do
      @item.fix_tmp_files(params[:_tmp])
      @item = Faq::Doc.find_by(id: @item.id)
      send_recognition_request_mail(@item) if @item.state == 'recognize'
      publish_by_update(@item) if @item.state == 'public'
    end
  end

  def update
    @item = Faq::Doc.find(params[:id])

    ## reset related docs
    @item.in_rel_doc_ids = [] if @item.in_rel_doc_ids.present? && docs_params[:in_rel_doc_ids].blank?

    @item.attributes = docs_params
    @item.state      = 'draft'
    @item.state      = 'recognize' if params[:commit_recognize]
    @item.state      = 'public'    if params[:commit_public]

    ## convert sys urls
    unid = params[:_tmp] || @item.unid
    @item.body = @item.body.gsub(::File.join(Core.site.full_uri, faq_preview_doc_file_path(parent: unid)), '.')

    _update(@item) do
      send_recognition_request_mail(@item) if @item.state == 'recognize'
      publish_by_update(@item) if @item.state == 'public'
      @item.close unless @item.public?
    end
  end

  def destroy
    @item = Faq::Doc.find(params[:id])
    _destroy @item
  end

  def recognize(item)
    _recognize(item) do
      if @item.state == 'recognized'
        send_recognition_success_mail(@item)
      elsif @recognition_type == 'with_admin'
        if item.recognition.recognized_all?(false)
          users = Sys::User.find_managers
          send_recognition_request_mail(@item, users)
        end
      end
    end
  end

  def duplicate(item)
    if dupe_item = item.duplicate
      flash[:notice] = '複製処理が完了しました。'
      respond_to do |format|
        format.html { redirect_to url_for(action: :index) }
        format.xml  { head :ok }
      end
    else
      flash[:notice] = "複製処理に失敗しました。"
      respond_to do |format|
        format.html { redirect_to url_for(action: :show) }
        format.xml  { render xml: item.errors, status: :unprocessable_entity }
      end
    end
  end

  def duplicate_for_replace(item)
    if item.editable? && dupe_item = item.duplicate(:replace)
      flash[:notice] = '複製処理が完了しました。'
      respond_to do |format|
        format.html { redirect_to url_for(action: :index) }
        format.xml  { head :ok }
      end
    else
      flash[:notice] = "複製処理に失敗しました。"
      respond_to do |format|
        format.html { redirect_to url_for(action: :show) }
        format.xml  { render xml: item.errors, status: :unprocessable_entity }
      end
    end
  end

  def publish_ruby(item)
    uri  = item.public_uri
    uri  = (uri =~ /\?/) ? uri.gsub(/\?/, 'index.html.r?') : "#{uri}index.html.r"
    path = "#{item.public_path}.r"
    item.publish_page(render_public_as_string(uri, site: item.content.site),
                      path: path, uri: uri, dependent: :ruby)
  end

  def publish(item)
    item.public_uri = "#{item.public_uri}?doc_id=#{item.id}"
    _publish(item) { publish_ruby(item) }
  end

  def publish_by_update(item)
    item.public_uri = "#{item.public_uri}?doc_id=#{item.id}"
    if item.publish(render_public_as_string(item.public_uri))
      publish_ruby(item)
      flash[:notice] = "公開処理が完了しました。"
    else
      flash[:notice] = "公開処理に失敗しました。"
    end
  end

  protected

  def send_recognition_request_mail(item, users = nil)
    body = []
    body << "#{Core.user.name}さんより「#{item.title}」についての承認依頼が届きました。\n"
    body << "次の手順により，承認作業を行ってください。\n\n"
    body << "1. PC用記事のプレビューにより文書を確認\n"
    body << "#{item.preview_uri(params: { doc_id: item.id })}\n\n"
    body << "2. 次のリンクから承認を実施\n"
    body << "#{Core.site.admin_uri(path: faq_all_doc_path(id: item.id))}\n"

    (users || item.recognizers).each do |user|
      send_mail(to: user.email,
                from: Core.user.email,
                subject: "#{item.content.name} 承認依頼メール | #{item.content.site.name}",
                body: body.join)
    end
  end

  def send_recognition_success_mail(item)
    return true unless item.recognition
    return true unless item.recognition.user
    return true if item.recognition.user.email.blank?

    body = []
    body << "「#{item.title}」についての承認が完了しました。\n"
    body << "次のURLをクリックして公開処理を行ってください。\n\n"
    body << "#{Core.site.admin_uri(path: faq_all_doc_path(id: item.id))}\n\n"

    send_mail(from: Core.user.email,
              to: item.recognition.user.email,
              subject: "#{item.content.name} 最終承認完了メール | #{item.content.site.name}",
              body: body.join)
  end

  private

  def docs_params
    params.require(:item).permit(
      :title, :language_id, :question, :body, :recent_state, :agent_state,
      :mobile_body, :published_at, :in_recognizer_ids,
      in_tags: %w(0 1 2),
      in_rel_doc_ids: [],
      in_category_ids: %w(0 1 2),
      in_inquiry: [:state, :group_id, :charge, :tel, :fax, :email],
      in_editable_groups: %w(0 1 2),
      in_creator: [:group_id, :user_id])
  end
end
