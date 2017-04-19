module Herd
  class AssetsController < ApplicationController
    include ActionController::Live

    respond_to :json, :html
    before_action :set_asset, only: [:show, :edit, :update, :destroy]

    def transform
      set_asset
      transforms = params[:options].split(';')
      child = @asset
      transforms.each { |t| child = child.t t }

      respond_to do |format|
        format.json { render json: child, serializer: AssetSerializer  }
        format.any { redirect_to child.file_url }
      end
    end

    def live
      return raise 'HERD_LIVE_ASSETS disabled' unless ENV['HERD_LIVE_ASSETS'] == '1'

      response.headers['Content-Type'] = 'text/event-stream'
      sse = SSE.new(response.stream, event:'assets')
      # NB: this is a blocking, infinite loop.
      Redis.new.subscribe('assets') do |on|
        on.message do |event, data|
          sse.write(data)
        end
      end

    rescue IOError
      puts "user closed connection"
    ensure
      sse.close if sse
    end

    # GET /assets
    def index
      @assets = scoped_assets

      respond_to do |format|
        format.json { render json: @assets,  each_serializer: AssetSerializer  }
        format.html
      end
    end

    def search
      @assets = Asset.where("meta LIKE ?","%#{params[:meta]}%")
      respond_to do |format|
        format.json { render json: @assets,  each_serializer: AssetSerializer  }
        format.html
      end
    end

    # GET /assets/1
    def show

      #TODO: make/use detail serializer
      respond_to do |format|
        #untested
        format.json {render json: @asset.child_assets || @asset, serializer: AssetSerializer}
        format.html
      end

    end

    # POST /assets
    def create
      if params[:asset] and params[:asset][:transform]# transform_params.present?
        parent = Asset.find(params[:asset][:parent_asset_id])

        klass = klass_for_type(params[:asset][:transform][:type]) rescue parent.class.default_transform
        params[:asset][:transform].delete(:type)

        #TODO: dont use default_transform here
        transform = unless transform_params[:name].empty?
          klass.find_by(name:transform_params[:name]).tap do |t|
            if t and transform_params[:options]
              t_options = if transform_params[:options].kind_of? String
                t.class.options_from_string(transform_params[:options])
              else
                transform_params[:options]
              end
              unless t_options == t.options
                t.options = t_options
                t.save
              end
            end
          end
        end
        transform ||= klass.where_t(transform_params).first_or_create do |t|
          t_options = if transform_params[:options].kind_of? String
            t.class.options_from_string(transform_params[:options])
          else
            transform_params[:options]
          end
          t.options = t_options
        end

        #TODO: check for / respond w errors here
        params[:asset][:transform_id] = transform.id
        @asset = parent.child_with_transform(transform)
      end

      if request.content_type =~ /^(image|video)/

        tmp = if asset_params[:file_name].presence
          tmp_path = Dir::Tmpname.tmpdir + "/" + asset_params[:file_name]
          File.new(tmp_path, 'wb')
        else
          Tempfile.new(['unnamed', '.'+MIME::Types[request.content_type].first.try(:preferred_extension)])
        end

        tmp.binmode
        tmp.write request.body.read

        file = File.open(tmp.path)
        @asset = Asset.create asset_params.merge(file: file)

      elsif asset_params[:file].kind_of? String
        @asset = Asset.find_by("meta like ?", "%content_url: #{asset_params[:file]}%")
      end

      if @asset ||= Asset.create(asset_params)

        @asset.generate unless @asset.jid or @asset.file_name

        if metadata_params.present?
          pre = @asset.meta
          @asset.meta.reverse_merge! metadata_params
          @asset.save unless pre == @asset.meta
        end

        if params[:response_action] == "back"
          redirect_to :back
        else
          render json: @asset, serializer: AssetSerializer
        end
        # respond_to do |format|
        #   # format.html { redirect_to :back }
        #   format.any { }
        # end

      else
        render json: @asset.errors, status: :unprocessable_entity
      end

    end

    # PATCH/PUT /assets/1
    def update
      if @asset.update(asset_params)
        if metadata_params.present?
          @asset.meta.merge! metadata_params
          @asset.save if @asset.meta_changed?
        end
        respond_with(@asset, serializer: AssetSerializer)
      else
        render :edit
      end
    end

    # DELETE /assets/1
    def destroy
      @asset.destroy

      if params[:response_action] == "back"
        redirect_to :back
      else
        head :no_content
      end
    end

    def scoped_assets
      assets = Asset.order :position
      if params[:assetable_type].present?
        assets = assets.where params.permit(:assetable_type,:assetable_id)
      elsif params[:parent_id].present?
        assets = assets.where parent_asset_id:params.require(:parent_id)
      elsif params[:ids].present?
        assets = assets.where id:params.require(:ids)
      end
      assets
    end

    private

      def klass_for_type(type)
        type.constantize
      end

      # Use callbacks to share common setup or constraints between actions.
      def set_asset
        @asset = Asset.find(params[:id])
      end

      # Only allow a trusted parameter "white list" through.
      def asset_params
        if params[:asset]
          sanitized = params.require(:asset).permit(:file, :file_name, :parent_asset_id, :transform_id, :assetable_type, :assetable_id, :position, :created_at, :updated_at)
          assetable_slug = params[:asset][:assetable_slug]

          # If the uploader passes :assetable_slug instead, prepare the asset_params appropriately
          if sanitized[:assetable_id].nil? && assetable_slug
            klass     = klass_for_type sanitized[:assetable_type]
            assetable = klass.find_by_assetable_slug assetable_slug

            sanitized[:assetable_id] = assetable.id if assetable
          end
          sanitized
        else
          []
        end
      end
      def metadata_params
        params.require(:asset).require(:metadata).permit!.symbolize_keys if asset_params.try(:metadata)
      end
      def transform_params
        params.require(:asset).require(:transform).permit! if asset_params#(:type, :options, :format, :name, :assetable_type, :created_at, :updated_at, :async) if asset_params
      end
  end
end
