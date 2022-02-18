# frozen_string_literal: true

module DeviseTokenAuth
  class RegistrationsController < DeviseTokenAuth::ApplicationController
    before_action :set_user_by_token, only: [:destroy, :update]
    before_action :validate_sign_up_params, only: :create
    before_action :validate_account_update_params, only: :update
    skip_after_action :update_auth_header, only: [:create, :destroy]

    def create
      build_resource

      unless @resource.present?
        raise DeviseTokenAuth::Errors::NoResourceDefinedError,
              "#{self.class.name} #build_resource does not define @resource,"\
              ' execution stopped.'
      end

      # give redirect value from params priority
      @redirect_url = params.fetch(
        :confirm_success_url,
        DeviseTokenAuth.default_confirm_success_url
      )
      
      
      @redirect_url = request.headers['origin']
      @tk = ""
      if params['workspace_nome'].present?
        # @redirect_url = @redirect_url.gsub('app', params["workspace_subdominio"]) if @redirect_url.include? "app"
        @redirect_url += "?" #/login/preparando
        # @tk = Base64.encode64(params.permit("workspace_convite_obrigatorio", "workspace_nome", "workspace_subdominio",
        #   "workspace_telefone", "workspace_faixa_colaboradores", "workspace_plano", "workspace_periodo").to_query)
        @tk = params.permit("workspace_convite_obrigatorio", "workspace_nome", "workspace_subdominio",
          "workspace_telefone", "workspace_faixa_colaboradores", "workspace_plano", "workspace_periodo").to_query
        @redirect_url += "criar_token="#=#{CGI::escape(@tk)}"
        # @redirect_url = CGI::escape @redirect_url
      end

      # success redirect url is required
      if confirmable_enabled? && !@redirect_url
        return render_create_error_missing_confirm_success_url
      end

      # if whitelist is set, validate redirect_url against whitelist
      return render_create_error_redirect_url_not_allowed if blacklisted_redirect_url?(@redirect_url)

      # override email confirmation, must be sent manually from ctrl
      callback_name = defined?(ActiveRecord) && resource_class < ActiveRecord::Base ? :commit : :create
      resource_class.set_callback(callback_name, :after, :send_on_create_confirmation_instructions)
      resource_class.skip_callback(callback_name, :after, :send_on_create_confirmation_instructions)

      if @resource.respond_to? :skip_confirmation_notification!
        # Fix duplicate e-mails by disabling Devise confirmation e-mail
        @resource.skip_confirmation_notification!
      end

      @resource.origin = request.headers['origin']
      
      if @resource.save
        yield @resource if block_given?

        unless @resource.confirmed?
          # user will require email authentication
          @redirect_url = @resource.send_confirmation_instructions({
            client_config: params[:config_name],
            redirect_url: @redirect_url,
            tk: @tk
            # api.calend.aomc.br/auth/confirmation?confirmation_token=98jiud98asdjas98djas9d8asj&redirect_url=luanda.calenda.com.br/create_token=0912okadspodkaspodkaspdoakdpos
          })
        end

        if active_for_authentication?
          # email auth has been bypassed, authenticate user
          @token = @resource.create_token
          @resource.save!
          update_auth_header
        end

        render_create_success
      else
        clean_up_passwords @resource
        render_create_error
      end
    end

    def update
      if @resource.blank? && params[:reset_password_token].present?
        @resource = resource_class.with_reset_password_token params[:reset_password_token]
      end
      
      if @resource
        if @resource.send(resource_update_method, account_update_params)
          yield @resource if block_given?
          render_update_success
        else
          render_update_error
        end
      else
        render_update_error_user_not_found
      end
    end

    def destroy
      if @resource
        @resource.destroy
        yield @resource if block_given?
        render_destroy_success
      else
        render_destroy_error
      end
    end

    def sign_up_params
      params.permit(*params_for_resource(:sign_up))
    end

    def account_update_params
      params.permit(*params_for_resource(:account_update))
    end

    protected

    def build_resource
      @resource            = resource_class.new(sign_up_params)
      @resource.provider   = provider

      # honor devise configuration for case_insensitive_keys
      if resource_class.case_insensitive_keys.include?(:email)
        @resource.email = sign_up_params[:email].try(:downcase)
      else
        @resource.email = sign_up_params[:email]
      end
    end

    def render_create_error_missing_confirm_success_url
      response = {
        status: 'error',
        data:   resource_data
      }
      message = I18n.t('devise_token_auth.registrations.missing_confirm_success_url')
      render_error(422, message, response)
    end

    def render_create_error_redirect_url_not_allowed
      response = {
        status: 'error',
        data:   resource_data
      }
      message = I18n.t('devise_token_auth.registrations.redirect_url_not_allowed', redirect_url: @redirect_url)
      render_error(422, message, response)
    end

    def render_create_success
      response = {
        status: 'success',
        data:   resource_data
      }
      response[:redirect_url] = @redirect_url unless Rails.env.production?
      render json: response
    end

    def render_create_error
      render json: {
        status: 'error',
        data:   resource_data,
        errors: resource_errors
      }, status: 422
    end

    def render_update_success
      render json: {
        status: 'success',
        data:   resource_data
      }
    end

    def render_update_error
      render json: {
        status: 'error',
        errors: resource_errors
      }, status: 422
    end

    def render_update_error_user_not_found
      render_error(404, I18n.t('devise_token_auth.registrations.user_not_found'), status: 'error')
    end

    def render_destroy_success
      render json: {
        status: 'success',
        message: I18n.t('devise_token_auth.registrations.account_with_uid_destroyed', uid: @resource.uid)
      }
    end

    def render_destroy_error
      render_error(404, I18n.t('devise_token_auth.registrations.account_to_destroy_not_found'), status: 'error')
    end

    private

    def resource_update_method
      if DeviseTokenAuth.check_current_password_before_update == :attributes
        'update_with_password'
      elsif DeviseTokenAuth.check_current_password_before_update == :password && account_update_params.key?(:password)
        'update_with_password'
      elsif account_update_params.key?(:current_password)
        'update_with_password'
      else
        'update'
      end
    end

    def validate_sign_up_params
      validate_post_data sign_up_params, I18n.t('errors.messages.validate_sign_up_params')
    end

    def validate_account_update_params
      validate_post_data account_update_params, I18n.t('errors.messages.validate_account_update_params')
    end

    def validate_post_data which, message
      render_error(:unprocessable_entity, message, status: 'error') if which.empty?
    end

    def active_for_authentication?
      !@resource.respond_to?(:active_for_authentication?) || @resource.active_for_authentication?
    end
  end
end
