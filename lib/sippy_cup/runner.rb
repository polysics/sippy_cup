require 'yaml'
require 'logger'
require 'active_support/core_ext/hash'

module SippyCup
  class Runner
    attr_accessor :sipp_pid
    attr_accessor :logger

    def initialize(opts = {})
      @options = ActiveSupport::HashWithIndifferentAccess.new opts
      @logger = @options[:logger] || Logger.new(STDOUT)
    end

    def compile
      raise ArgumentError, "Must provide scenario steps" unless @options[:steps]

      scenario_opts = {source: @options[:source], destination: @options[:destination]}
      scenario_opts[:filename] = @options[:filename] if @options[:filename]
      scenario = SippyCup::Scenario.new @options[:name].titleize, scenario_opts
      @options[:steps].each do |step|
        instruction, arg = step.split ' ', 2
        if arg && !arg.empty?
          # Strip leading/trailing quotes if present
          arg.gsub!(/^'|^"|'$|"$/, '')
          scenario.send instruction.to_sym, arg
        else
          scenario.send instruction
        end
      end
      scenario.compile!
    end

    def prepare_command
      [:scenario, :source, :destination, :max_concurrent, :calls_per_second, :number_of_calls].each do |arg|
        raise ArgumentError, "Must provide #{arg}!" unless @options[arg]
      end
      command = "sudo sipp"
      source_port = @options[:source_port] || '8836'
      sip_user = @options[:sip_user] || '1'
      command << " -i #{@options[:source]} -p #{source_port} -sf #{File.expand_path @options[:scenario]}.xml"
      command << " -l #{@options[:max_concurrent]} -m #{@options[:number_of_calls]} -r #{@options[:calls_per_second]}"
      command << " -s #{sip_user}"
      if @options[:stats_file]
        stats_interval = @options[:stats_interval] || 1
        command << " -trace_stat -stf #{@options[:stats_file]} -fd #{stats_interval}"
      end
      command << " -inf #{@options[:scenario_variables]}" if @options[:scenario_variables]
      command << " #{@options[:destination]}"
      command << " > /dev/null 2>&1" unless @options[:full_sipp_output]
      command
    end

    # Runs the loaded scenario using SIPp
    #
    # @raises Errno::ENOENT when the SIPp executable cannot be found
    # @raises SippyCup::ExitOnInternalCommand when SIPp exits on an internal command. Calls may have been processed
    # @raises SippyCup::NoCallsProcessed when SIPp exit normally, but has processed no calls
    # @raises SippyCup::FatalError when SIPp encounters a fatal failure
    # @raises SippyCup::FatalSocketBindingError when SIPp fails to bind to the specified socket
    #
    # @return Boolean true if execution succeeded without any failed calls, false otherwise
    #
    def run
      command = prepare_command
      @logger.info "Preparing to run SIPp command: #{command}"

      @sipp_pid = spawn command
      sipp_result = Process.wait2 @sipp_pid.to_i

      final_result = process_exit_status sipp_result

      if final_result
        @logger.info "Test completed successfully!"
      else
        @logger.info "Test completed successfully but some calls failed."
      end
      @logger.info "Statistics logged at #{File.expand_path @options[:stats_file]}" if @options[:stats_file]

      final_result
    end

    #
    # Tries to stop SIPp by killing the target PID
    #
    # @raises Errno::ESRCH when the PID does not correspond to a known process
    # @raises Errno::EPERM when the process referenced by the PID cannot be killed
    #
    def stop
      Process.kill "KILL", @sipp_pid if @sipp_pid
    end

    def process_exit_status(process_status)
      exit_code = process_status[1].exitstatus
      case exit_code
      when 1
        false
      when 97
        raise SippyCup::ExitOnInternalCommand
      when 99
        raise SippyCup::NoCallsProcessed
      when -1
        raise SippyCup::FatalError
      when -2
        raise SippyCup::FatalSocketBindingError
      else
        true
      end
    end
  end

  # The corresponding SIPp error code is listed after the exception
  class Error < StandardError; end
  class ExitOnInternalCommand < Error; end # 97
  class NoCallsProcessed < Error; end # 99
  class FatalError < Error; end # -1
  class FatalSocketBindingError < Error; end # -2
end
