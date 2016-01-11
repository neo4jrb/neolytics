module Neo4Apis
  class Neolytics < Base
    module TracePointHelpers

      class << self

        FILE_LINES = {}

        def each_received_arguments(tp)
          # Can't just use #method method because some objects implement a #method method
          method = if tp.self.class.instance_method(:method).source_location.nil?
            tp.self.method(tp.method_id)
          else
            tp.self.class.instance_method(tp.method_id)
          end
          parameter_names = method.parameters.map {|_, name| name }
          arguments = parameter_names.compact.each_with_object({}) do |name, arguments|
            catch :not_found do
              begin
              arguments[name] = get_trace_point_var(tp, name)
              rescue Exception => e
                require 'pry'
                binding.pry
              end
            end
          end
          arguments.each do |name, object|
            yield name, object
          end
        end

        def each_referenced_variable(tp)
          line = get_file_line(tp.path, tp.lineno)
          root = Parser::CurrentRuby.parse(line)
          extract_variables(root).each do |variable|
            catch :not_found do
              value = get_trace_point_var(tp, variable)
              yield variable, value
            end
          end
        rescue Parser::SyntaxError
          nil
        end

        def each_referenced_object(tp)
          line = get_file_line(tp.path, tp.lineno)
          root = Parser::CurrentRuby.parse(line)
          extract_object_references(root).each do |inspect_string|
            value = tp.binding.eval(inspect_string)
            yield value
          end
        rescue Parser::SyntaxError
          nil
        end

        private

        def extract_variables(ast_node)
          if ast_node.is_a?(Parser::AST::Node)
            if ast_node.type == :send &&
                 ast_node.children.size == 2 &&
                 ast_node.children[0].nil?
              [ast_node.children[1]]
            else
              ast_node.children.flat_map do |child|
                extract_variables(child)
              end
            end
          else
            []
          end
        end

        OBJECT_NODE_TYPES = [:str, :sym, :int, :float, :hash, :array, :true, :false, :nil]
        def extract_object_references(ast_node)
          if ast_node.is_a?(Parser::AST::Node)
            if OBJECT_NODE_TYPES.include?(ast_node.type)
              [ast_node.children[0].inspect]
            else
              ast_node.children.flat_map do |child|
                extract_object_references(child)
              end
            end
          else
            []
          end
        end

        def get_file_line(path, lineno)
          return '' if path == '(eval)'
          FILE_LINES[path] ||= File.read(path).lines

          FILE_LINES[path][lineno - 1]
        end

        def get_trace_point_var(tp, var_name)
          begin
            tp.binding.local_variable_get(var_name)
          rescue NameError
            throw :not_found
          end
        end
      end
    end
  end
end