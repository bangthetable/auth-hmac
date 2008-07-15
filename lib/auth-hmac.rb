# Copyright (c) 2008 The Kaphan Foundation
#
# See License.txt for licensing information.
#

$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

require 'openssl'
require 'base64'

# This module provides a HMAC Authentication method for HTTP requests. It should work with
# net/http request classes and CGIRequest classes and hence Rails.
#
# It is loosely based on the Amazon Web Services Authentication mechanism but
# generalized to be useful to any application that requires HMAC based authentication.
# As a result of the generalization, it won't work with AWS because it doesn't support
# the Amazon extension headers.
#
class AuthHMAC
  module Headers
    # Gets the headers for a request.
    #
    # Attempts to deal with known HTTP header representations in Ruby.
    # Currently handles net/http and Rails.
    #
    def headers(request)
      if request.respond_to?(:[])
        request
      elsif request.respond_to?(:headers)
        request.headers
      else
        raise ArgumentError, "Don't know how to get the headers from #{request.inspect}"
      end
    end
  end
  
  include Headers
  
  # Signs a request using a given access key id and secret.
  #
  def AuthHMAC.sign!(request, access_key_id, secret)
    self.new(access_key_id => secret).sign!(request, access_key_id)
  end
  
  # Create an AuthHMAC instance using a given credential store.
  #
  # A credential store must respond to the [] method and return
  # the secret for the access key id passed to [].
  #
  def initialize(credential_store)
    @credential_store = credential_store
  end
  
  # Signs a request using the access_key_id and the secret associated with that id
  # in the credential store.
  #
  # Signing a requests adds an Authorization header to the request in the format:
  #
  #  AuthHMAC <access_key_id>:<signature>
  #
  # where <signature> is the Base64 encoded HMAC-SHA1 of the CanonicalString and the secret.
  #
  def sign!(request, access_key_id)
    secret = @credential_store[access_key_id]
    raise ArgumentError, "No secret found for key id '#{access_key_id}'" if secret.nil?
    request['Authorization'] = build_authorization_header(request, access_key_id, secret)
  end
  
  # Authenticates a request using HMAC
  #
  # Returns true if the request has an AuthHMAC Authorization header and
  # the access id and HMAC match an id and HMAC produced for the secret
  # in the credential store. Otherwise returns false.
  #
  def authenticated?(request)
    if md = /^AuthHMAC ([^:]+):(.+)$/.match(headers(request)['Authorization'])
      access_key_id = md[1]
      hmac = md[2]
      secret = @credential_store[access_key_id]      
      !secret.nil? && hmac == build_signature(request, secret)
    else
      false
    end
  end
  
  private
    def build_authorization_header(request, access_key_id, secret)
      "AuthHMAC #{access_key_id}:#{build_signature(request, secret)}"      
    end
    
    def build_signature(request, secret)
      digest = OpenSSL::Digest::Digest.new('sha1')
      Base64.encode64(OpenSSL::HMAC.digest(digest, secret, CanonicalString.new(request))).strip
    end
  
  # Build a Canonical String for a HTTP request.
  #
  # A Canonical String has the following format:
  #
  # CanonicalString = HTTP-Verb    + "\n" +
  #                   Content-Type + "\n" +
  #                   Content-MD5  + "\n" +
  #                   Date         + "\n" +
  #                   request-uri;
  #
  class CanonicalString < String
    include Headers
    
    def initialize(request)
      self << request_method(request) + "\n"
      self << header_values(headers(request)) + "\n"
      self << request_path(request)
    end
    
    private
      def request_method(request)
        if request.method.is_a?(String)
          request.method
        elsif request.env
          request.env['REQUEST_METHOD']
        else
          raise ArgumentError, "Don't know how to get the request method from #{request.inspect}"
        end
      end
      
      def header_values(headers)
        [ headers['content-type'], 
          headers['content-md5'], 
          headers['date']
        ].join("\n")
      end
      
      
      
      def request_path(request)
        request.path[/^[^?]*/]
      end
  end
    
  class Rails
    module ControllerFilter
      module ClassMethods
        # Call within a Rails Controller to initialize HMAC authentication for the controller.
        #
        #  * +credentials+ must be a hash that indexes secrets by their access key id.
        #  * +options+ supports the following arguments:
        #       * +failure_message+: The text to use when authentication fails.
        #       * +only+: A list off actions to protect.
        #       * +except: A list of actions to not protect.
        #
        def with_auth_hmac(credentials, options = {})
          self.credentials = credentials
          self.authhmac = AuthHMAC.new(self.credentials)
          self.authhmac_failure_message = (options.delete(:failure_message) or "HMAC Authentication failed")
          before_filter(:hmac_login_required, options)
        end
      end
      
      module InstanceMethods
        def hmac_login_required          
          unless self.class.authhmac.authenticated?(request)
            render :text => self.class.authhmac_failure_message, :status => :forbidden
          end
        end
      end
      
      unless defined?(ActionController)
        begin
          require 'rubygems'
          gem 'actionpack'
          gem 'activesupport'
          require 'action_controller'
          require 'active_support'
        rescue
          nil
        end
      end
      
      if defined?(ActionController::Base)        
        ActionController::Base.class_eval do
          class_inheritable_accessor :authhmac
          class_inheritable_accessor :credentials
          class_inheritable_accessor :authhmac_failure_message
        end
        
        ActionController::Base.send(:include, ControllerFilter::InstanceMethods)
        ActionController::Base.extend(ControllerFilter::ClassMethods)
      end
    end
  end
end