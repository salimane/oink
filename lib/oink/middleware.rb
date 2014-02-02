require 'hodel_3000_compliant_logger'
require 'oink/utils/hash_utils'
require 'oink/instrumentation'

module Oink
  class Middleware

    def initialize(app, options = {})
      @app         = app
      @path        = options[:path] || false
      @logger      = options[:logger] || Hodel3000CompliantLogger.new("log/oink.log")
      @instruments = options[:instruments] ? Array(options[:instruments]) : [:memory, :activerecord]

      Oink.extend_active_record! if @instruments.include?(:activerecord)
    end

    def call(env)
      status, headers, body = @app.call(env)

      log_routing(env)
      log_memory
      log_activerecord
      log_completed
      [status, headers, body]
    end

    def log_completed
      @logger.info("Oink Log Entry Complete")
    end

    def log_routing(env)
      info = rails3_routing_info(env) || rails2_routing_info(env)
      if info
        if @path && info[:path_info]
          @logger.info("Oink Path: #{info[:path_info]}")
        elsif info[:request]
          @logger.info("Oink Action: #{info[:request]['controller']}##{info[:request]['action']}")
        end
        @logger.info("Oink Params: #{info[:params]}")
      end
    end

    def log_memory
      if @instruments.include?(:memory)
        memory = Oink::Instrumentation::MemorySnapshot.memory
        @logger.info("Memory usage: #{memory} | PID: #{$$}")
      end
    end

    def log_activerecord
      if @instruments.include?(:activerecord)
        sorted_list = Oink::HashUtils.to_sorted_array(ActiveRecord::Base.instantiated_hash)
        sorted_list.unshift("Total: #{ActiveRecord::Base.total_objects_instantiated}")
        @logger.info("Instantiation Breakdown: #{sorted_list.join(' | ')}")
        reset_objects_instantiated
      end
    end

  private

    def rails3_routing_info(env)
      if env['api.endpoint']
        {
          :request => grape_controller_action(env['api.endpoint']),
          :path_info => grape_path_info(env['api.endpoint']),
          :params => grape_request_params(env['api.endpoint'])
        }
      elsif env['action_dispatch.request.parameters']
        {
          :request => env['action_dispatch.request.parameters'],
          :path_info => env['PATH_INFO'],
          :params => rails_request_params(env)
        }
      else
        nil
      end
    end

    def rails2_routing_info(env)
      if env['action_controller.request.path_parameters']
        {
          :request => env['action_controller.request.path_parameters'],
          :path_info => env['PATH_INFO'],
          :params => ''
        }
      else
        nil
      end
    end

    def reset_objects_instantiated
      ActiveRecord::Base.reset_instance_type_count
    end

    def rails_request_params(env)
      params = ''
      if env['action_dispatch.request.request_parameters'] && \
        env['action_dispatch.request.request_parameters'].length > 0
        params = "#{env['action_dispatch.request.request_parameters']}"
      end
      if env['action_dispatch.request.query_parameters'] && \
        env['action_dispatch.request.query_parameters'].length > 0
        params = "#{params} #{env['action_dispatch.request.query_parameters']}"
      end

      params
    end

    def grape_request_params(endpoint)
      endpoint.env ? "#{endpoint.env['rack.request.query_hash']}" : ''
    end

    def grape_controller_action(endpoint)
      request = {'controller' => '', 'action' => ''}
      if grape_current_route(endpoint).match(/(.*)(\/(.*))/)
        request = {'controller' => $1, 'action' => $3}
      end

      request
    end

    def grape_path_info(endpoint)
      endpoint.env ? endpoint.env['PATH_INFO'] : grape_current_route(endpoint)
    end

    def grape_current_route(endpoint)
      endpoint.routes.first.route_path[1..-1].sub(/\(\.:format\)\z/, '')
    end

  end
end
