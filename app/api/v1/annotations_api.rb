class V1::AnnotationsAPI < Grape::API
  include V1Base

  resource :documents do
    namespace ':id', requirements: { id: uuid_pattern } do
      before do
        fetch_and_authorize_document!
      end

      resource :annotations do
        desc "Lists used categories in the document"
        get 'categories' do
          present Annotations::QueryCategories.run!(
            document: @document
          ).result
        end
      end

      namespace ':revision' do
        before do
          infer_revision! fetch: true
        end

        resource :annotations do
          before do
            infer_editor!
          end

          desc "Creates a new annotation within the document"
          params do
            requires :content, type: String
            requires :surface_number, type: Integer
            requires :areas, type: Array do
              requires :ulx, type: Integer
              requires :lrx, type: Integer
              requires :uly, type: Integer
              requires :lry, type: Integer
            end
            requires :mode, type: String
            optional :payload, type: JSON
          end
          post do
            action! Annotations::Create, content: params[:content],
              editor_id: @editor_id,
              surface_number: params[:surface_number],
              revision: @revision || @branch.revision,
              areas: params[:areas].map { |a| Area.new(a) },
              mode: params[:mode],
              payload: params[:payload]
          end

          desc "Corrects an annotation for a given version"
          params do
            requires :content, type: String
            requires :mode, type: String
            optional :payload, type: JSON
          end
          put ':annotation_id' do
            action! Annotations::Correct, id: params[:annotation_id],
              editor_id: @editor_id,
              content: params[:content],
              revision: @revision || @branch.revision,
              mode: params[:mode],
              payload: params[:payload]
          end

          desc "Unlinks annotation from revision"
          delete ':annotation_id' do
            action! Annotations::Unlink, id: params[:annotation_id],
              revision: @revision || @branch.revision
          end

          desc "Lists annotations"
          params do
            requires :surface_number, type: Integer
          end
          get do
            @annotations = action! Annotations::QueryAll,
              surface_number: params[:surface_number],
              revision: @revision || @branch.revision

            present @annotations, with: Annotation::WithEditor
          end
        end
      end
    end
  end
end
