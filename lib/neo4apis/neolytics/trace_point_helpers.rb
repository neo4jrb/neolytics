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
          arguments = parameter_names.each_with_object({}) do |name, arguments|
            catch :not_found do
              arguments[name] = get_trace_point_var(tp, name)
            end
          end
          arguments.each do |name, object|
            value = RubyObject.from_object(object)
            yield name, value
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

        def get_file_line(path, lineno)
          FILE_LINES[path] ||= File.read(path).lines

          FILE_LINES[path][lineno - 1]
        end

        def get_trace_point_var(tp, var_name)
          begin
            tp.binding.local_variable_get(variable)
          rescue NameError
            throw :not_found
          end
        end
      end
    end
  end
end