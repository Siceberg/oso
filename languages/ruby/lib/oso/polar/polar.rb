# frozen_string_literal: true

require 'json'
require 'pp'
require 'set'

module Oso
  module Polar
    # Create and manage an instance of the Polar runtime.
    class Polar
      # @return [Host]
      attr_reader :host

      def initialize
        @ffi_polar = FFI::Polar.create
        @host = Host.new(ffi_polar)
        @load_queue = Set.new
      end

      # Replace the current Polar instance but retain all registered classes and constructors.
      def clear
        load_queue.clear
        @ffi_polar = FFI::Polar.create
      end

      # Enqueue a Polar policy file for loading into the KB.
      #
      # @param name [String]
      # @raise [PolarFileExtensionError] if provided filename has invalid extension.
      # @raise [PolarFileNotFoundError] if provided filename does not exist.
      def load_file(name)
        raise PolarFileExtensionError unless ['.pol', '.polar'].include? File.extname(name)
        raise PolarFileNotFoundError, name unless File.file?(name)

        load_queue << name
      end

      # Load a Polar string into the KB.
      #
      # @param str [String] Polar string to load.
      # @param filename [String] Name of Polar source file.
      # @raise [NullByteInPolarFileError] if str includes a non-terminating null byte.
      # @raise [InlineQueryFailedError] on the first failed inline query.
      # @raise [Error] if any of the FFI calls raise one.
      def load_str(str, filename: nil) # rubocop:disable Metrics/MethodLength
        raise NullByteInPolarFileError if str.chomp("\0").include?("\0")

        ffi_polar.load_str(str, filename: filename)
        loop do
          next_query = ffi_polar.next_inline_query
          break if next_query.nil?

          begin
            Query.new(next_query, host: host).results.next
          rescue StopIteration
            raise InlineQueryFailedError
          end
        end
      end

      # Query for a predicate, parsing it if necessary.
      #
      # @param query [String or Predicate]
      # @return Enumerator of resulting bindings
      # @raise [Error] if the FFI call raises one.
      def query(query)
        load_queued_files
        new_host = host.dup
        case query
        when String
          ffi_query = ffi_polar.new_query_from_str(query)
        when Predicate
          ffi_query = ffi_polar.new_query_from_term(new_host.to_polar_term(query))
        else
          raise InvalidQueryTypeError
        end
        Query.new(ffi_query, host: new_host).results
      end

      # Query for a rule.
      #
      # @param name [String]
      # @param args [Array<Object>]
      # @raise [Error] if the FFI call raises one.
      def query_rule(name, *args)
        query(Predicate.new(name, args: args))
      end

      # Start a REPL session.
      #
      # @raise [Error] if the FFI call raises one.
      def repl(load: false) # rubocop:disable Metrics/MethodLength
        ARGV.map { |f| load_file(f) } if load
        load_queued_files

        loop do
          print('query> ')
          begin
            query = STDIN.readline.chomp.chomp(';')
          rescue EOFError
            return
          end

          begin
            ffi_query = ffi_polar.new_query_from_str(query)
          rescue ParseError => e
            puts("Parse error: " + e.to_s)
            next
          end

          begin
            results = Query.new(ffi_query, host: host).results.to_a
          rescue PolarRuntimeError => e
            puts(e.to_s)
            next
          end

          if results.empty?
            pp false
          else
            results.each do |result|
              if result.empty?
                pp true
              else
                pp result
              end
            end
          end
        end
      end

      # Register a Ruby class with Polar.
      #
      # @param cls [Class]
      # @param name [String]
      # @param from_polar [Proc]
      # @raise [InvalidConstructorError] if provided an invalid 'from_polar' constructor.
      def register_class(cls, name: nil, from_polar: nil)
        if block_given?
          from_polar = Proc.new
        end
        name = host.cache_class(cls, name: name, constructor: from_polar)
        register_constant(name, value: cls)
      end

      def register_constant(name, value:)
        ffi_polar.register_constant(name, value: host.to_polar_term(value))
      end

      # Load all queued files, flushing the {#load_queue}.
      def load_queued_files
        load_queue.reject! do |filename|
          File.open(filename) { |file| load_str(file.read, filename: filename) }
          true
        end
      end

      private

      # @return [FFI::Polar]
      attr_reader :ffi_polar
      # @return [Array<String>]
      attr_reader :load_queue
    end
  end
end