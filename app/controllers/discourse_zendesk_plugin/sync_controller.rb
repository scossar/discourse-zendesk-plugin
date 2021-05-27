# frozen_string_literal: true

module DiscourseZendeskPlugin
  class SyncController < ApplicationController
    include ::DiscourseZendeskPlugin::Helper
    layout false
    before_action :zendesk_token_valid?, only: :webhook
    skip_before_action :check_xhr,
                       :preload_json,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       only: :webhook

    def webhook
      unless SiteSetting.zendesk_enabled? && SiteSetting.sync_comments_from_zendesk
        return render json: failed_json, status: 422
      end

      ticket_id = params[:ticket_id]
      raise Discourse::InvalidParameters.new(:ticket_id) if ticket_id.blank?
      topic = Topic.find_by_id(params[:topic_id])
      raise Discourse::InvalidParameters.new(:topic_id) if topic.blank?
      return if !DiscourseZendeskPlugin::Helper.category_enabled?(topic.category_id)

      user = User.find_by_email(params[:email]) || Discourse.system_user
      latest_comment = get_latest_comment(ticket_id)
      if latest_comment.present?
        existing_comment = PostCustomField.where(name: ::DiscourseZendeskPlugin::ZENDESK_ID_FIELD, value: latest_comment.id).first

        unless existing_comment.present?
          post = topic.posts.create!(
            user: user,
            raw: build_raw_post_body(latest_comment)
          )
          update_post_custom_fields(post, latest_comment)
        end
      end

      render json: {}, status: 204
    end

    def build_raw_post_body(comment)
      # Use body to preserve legacy
      # return comment.body unless SiteSetting.zendesk_append_attachments?

      # Prefer the html_body to preserve inline links if available possible
      prefix = comment.html_body.presence || comment.body.presence || ''
      prefix + build_attachments_body(comment)
    end

    def build_attachments_body(comment)
      return '' if comment.attachments.blank?

      "\n\n**Attachments**\n" + comment.attachments.map do |attachment|
        break '' if attachment.deleted
        thumbnail = attachment.thumbnails&.first
        if thumbnail.present? && thumbnail.deleted === false
          "[![](#{extract_content_url(thumbnail)})](#{extract_content_url(attachment)}) "
        else
          "\n* [#{attachment.file_name} (#{attachment.content_type})](#{extract_content_url(attachment)})"
        end
      end.sort.reverse.join('') # Put the thumbnails is a line above the links
    rescue StandardError => e
      ''
    end

    def extract_content_url(trackie)
      trackie.mapped_content_url.presence || trackie.content_url
    end

    private

    def zendesk_token_valid?
      params.require(:token)

      if SiteSetting.zendesk_incoming_webhook_token.blank? ||
         SiteSetting.zendesk_incoming_webhook_token != params[:token]

        raise Discourse::InvalidAccess.new
      end
    end
  end
end
