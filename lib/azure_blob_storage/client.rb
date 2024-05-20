# frozen_string_literal: true

require_relative "signer"
require_relative "block_list"
require_relative "blob_list"
require_relative "blob"
require "net/http"
require "time"
require "base64"

module AzureBlobStorage
  class Client
    def initialize(account_name:, access_key:, container:, debug: ENV['AZURE_BLOB_STORAGE_DEBUG'])
      @account_name = account_name
      @container = container
      @signer = Signer.new(account_name:, access_key:)

      uri = URI(host)

      @http = Net::HTTP.new(uri.hostname, uri.port)
      @http.use_ssl = true
      @http.set_debug_output($stdout) if debug
    end

    def create_block_blob(key, content, options = {})
      if content.size > (options[:block_size] || DEFAULT_BLOCK_SIZE)
        put_blob_multiple(key, content, **options)
      else
        put_blob_single(key, content, **options)
      end
    end

    def get_blob(key, options = {})
      uri = generate_uri("#{container}/#{key}")
      date = Time.now.httpdate

      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "x-ms-range": options[:start] && "bytes=#{options[:start]}-#{options[:end]}"
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "GET", headers:)

      response = http.start do |http|
        http.get(uri, headers)
      end
      raise_response(response) unless success?(response)
      response.body
    end

    def delete_blob(key, options = {})
      uri = generate_uri("#{container}/#{key}")
      date = Time.now.httpdate

      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "x-ms-delete-snapshots": options[:delete_snapshots] || "include",
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "DELETE", headers:)

      http.start do |http|
        http.delete(uri, headers)
      end.body
    end

    def delete_prefix(prefix, options = {})
      marker = nil
      loop do
        results = list_blobs(marker:, prefix:)
        results.each {|key| delete_blob(key)}
        break unless marker = results.marker
      end
    end

    def list_blobs(options = {})
      uri = generate_uri(container)
      date = Time.now.httpdate
      query = {
        comp: "list",
        restype: "container",
        prefix: options[:prefix].to_s.gsub(/\\/, "/"),
        marker: options[:marker].to_s,
      }
      query[:maxresults] = options[:max_results] if options[:max_results]
      uri.query = URI.encode_www_form(**query)

      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "GET", headers:)

      response = http.start do |http|
        http.get(uri, headers)
      end.body

      BlobList.new(response)
    end

    def get_blob_properties(key, options = {})
      uri = generate_uri("#{container}/#{key}")
      date = Time.now.httpdate

      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "x-ms-range": options[:start_range] && "bytes=#{options[:start]}-#{options[:end]}"
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "HEAD", headers:)

      response = http.start do |http|
        http.head(uri, headers)
      end
      raise_response(response) unless success?(response)
      Blob.new(response)
    end

    def generate_uri(path)
      URI.parse(URI::DEFAULT_PARSER.escape(File.join(host, path)))
    end

    def signed_uri(key, permissions:, expiry:)
      uri = generate_uri("#{container}/#{key}")
      uri.query = signer.sas_token(uri, permissions:, expiry:)
      uri
    end

    def create_append_blob(key, options = {})
      uri = generate_uri("#{container}/#{key}")
      date = Time.now.httpdate
      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "x-ms-blob-type": "AppendBlob",
        "Content-Length": 0.to_s,
        "Content-Type": options[:content_type].to_s, # Net::HTTP doesn't leave this empty if the value is nil
        "Content-MD5": options[:content_md5],
        "x-ms-blob-content-disposition": options[:content_disposition]
      }.reject { |_, value| value.nil? }

      options[:metadata]&.each do |key, value|
        headers[:"x-ms-meta-#{key}"] = value.to_s
      end

      headers[:Authorization] = signer.authorization_header(uri:, verb: "PUT", headers:)

      http.start do |http|
        http.put(uri, nil, headers)
      end
    end

    def append_blob_block(key, content, options = {})
      uri = generate_uri("#{container}/#{key}")
      uri.query = URI.encode_www_form(comp: "appendblock")

      date = Time.now.httpdate
      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "Content-Length": content.size.to_s,
        "Content-Type": options[:content_type].to_s, # Net::HTTP doesn't leave this empty if the value is nil
        "Content-MD5": options[:content_md5]
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "PUT", headers:)

      http.start do |http|
        http.put(uri, content, headers)
      end
    end

    def put_blob_block(key, index, content, options = {})
      block_id = generate_block_id(index)
      uri = generate_uri("#{container}/#{key}")
      uri.query = URI.encode_www_form(comp: "block", blockid: block_id)

      date = Time.now.httpdate
      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "Content-Length": content.size.to_s,
        "Content-Type": options[:content_type].to_s, # Net::HTTP doesn't leave this empty if the value is nil
        "Content-MD5": options[:content_md5]
      }.reject { |_, value| value.nil? }

      headers[:Authorization] = signer.authorization_header(uri:, verb: "PUT", headers:)

      http.start do |http|
        http.put(uri, content, headers)
      end
      block_id
    end

    def commit_blob_blocks(key, block_ids, options = {})
      block_list = BlockList.new(block_ids)
      content = block_list.to_s
      uri = generate_uri("#{container}/#{key}")
      uri.query = URI.encode_www_form(comp: "blocklist")

      date = Time.now.httpdate
      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "Content-Length": content.size.to_s,
        "Content-Type": options[:content_type].to_s, # Net::HTTP doesn't leave this empty if the value is nil
        "Content-MD5": options[:content_md5],
        "x-ms-blob-content-disposition": options[:content_disposition]
      }.reject { |_, value| value.nil? }

      options[:metadata]&.each do |key, value|
        headers[:"x-ms-meta-#{key}"] = value.to_s
      end

      headers[:Authorization] = signer.authorization_header(uri:, verb: "PUT", headers:)

      http.start do |http|
        http.put(uri, content, headers)
      end
    end

    private

    def success?(response)
       Net::HTTPResponse::CODE_TO_OBJ[response.code] < Net::HTTPSuccess
    end

    def raise_response(response)
      raise AzureBlobStorage.error_from_response_type(Net::HTTPResponse::CODE_TO_OBJ[response.code]).new
    end

    def generate_block_id(index)
      Base64.urlsafe_encode64(index.to_s.rjust(6, "0"))
    end

    def put_blob_multiple(key, content, options = {})
      content = StringIO.new(content) if content.is_a? String
      block_size = options[:block_size] || DEFAULT_BLOCK_SIZE
      block_count = (content.size.to_f / block_size).ceil
      block_ids = block_count.times.map do |i|
        put_blob_block(key, i, content.read(block_size))
      end

      commit_blob_blocks(key, block_ids, options)
    end

    def put_blob_single(key, content, options = {})
      content = StringIO.new(content) if content.is_a? String
      uri = generate_uri("#{container}/#{key}")
      date = Time.now.httpdate
      headers = {
        "x-ms-version": API_VERSION,
        "x-ms-date": date,
        "x-ms-blob-type": "BlockBlob",
        "Content-Length": content.size.to_s,
        "Content-Type": options[:content_type].to_s, # Net::HTTP doesn't leave this empty if the value is nil
        "Content-MD5": options[:content_md5],
        "x-ms-blob-content-disposition": options[:content_disposition]
      }.reject { |_, value| value.nil? }

      options[:metadata]&.each do |key, value|
        headers[:"x-ms-meta-#{key}"] = value.to_s
      end

      headers[:Authorization] = signer.authorization_header(uri:, verb: "PUT", headers:)

      http.start do |http|
        http.put(uri, content.read, headers)
      end
    end

    attr_reader :account_name, :signer, :container, :http

    def host
      "https://#{account_name}.blob.core.windows.net"
    end
  end
end
