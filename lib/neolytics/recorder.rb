require 'pathname'
require 'parser/current'
require 'neo4apis'
require 'neo4apis/neolytics'

module Neolytics
  class Recorder
    def initialize(neo4j_session)
      @neo4j_session = neo4j_session
      @neo4apis_session = Neo4Apis::Neolytics.new(neo4j_session)
    end

    def record(&block)
      @neo4apis_session.batch do
        record_execution_trace do
          begin
            block.call
          rescue Exception => e
            nil
          end
        end

        file_paths = @neo4j_session.query("MATCH (tp) WHERE NOT(tp.path IS NULL) RETURN DISTINCT tp.path AS path").map(&:path)
        file_paths.each(&method(:record_ast))

        link_query = <<QUERY
MATCH (tp:TracePoint), (node:ASTNode)
WHERE
  node.file_path = tp.path AND
  node.first_line = tp.lineno AND
  node.name = tp.method_id AND
  node.type = 'def'
MERGE (tp)-[:HAS_AST_NODE]->(node)
QUERY
        @neo4j_session.query(link_query)
      end
    end


    def record_ast(file_path)
      full_path = Pathname.new(file_path).realpath.to_s

      code = File.read(full_path)

      require 'parser/current'
      root = Parser::CurrentRuby.parse(code)

      file_node = @neo4apis_session.import :File, full_path, code
      node_node = @neo4apis_session.import :ASTNode, root, file_node
    end


    def record_execution_trace
      execution_index = 0
      indent = 0
      output = ''
      last_tracepoint_node = nil
      last_start_time = nil
      ancestor_stack = []
      run_time_stack = []

      last_tracepoint_end_time = nil
      last_run_time = nil

      trace = TracePoint.new do |tp|
        begin
          last_run_time = 1_000_000.0 * (Time.now - last_tracepoint_end_time) if last_tracepoint_end_time

          output << tracepoint_string(tp, indent)

          last_method_time = nil
          if [:call, :c_call].include?(tp.event)
            run_time_stack.push(0)
          elsif [:return, :c_return].include?(tp.event)
            last_method_time = run_time_stack.pop
          else
            run_time_stack[-1] += last_run_time if run_time_stack[-1] && last_run_time
          end

          associated_call = nil
          if [:return, :c_return].include?(tp.event) && indent.nonzero?
            indent -= 1
            associated_call = ancestor_stack.pop
          elsif [:call, :c_call].include?(tp.event)
            indent += 1
          end

          last_tracepoint_node = @neo4apis_session.import :TracePoint, tp,
                              last_method_time,
                              (execution_index += 1),
                              last_tracepoint_node,
                              ancestor_stack.last,
                              associated_call
          
          if [:call, :c_call].include?(tp.event)
            ancestor_stack.push(last_tracepoint_node)
          end

          last_tracepoint_end_time = Time.now
        rescue Exception => e
          puts 'EXCEPTION!!'
          puts e.message
          puts e.backtrace
          exit!
        end
      end

      trace.enable
      yield
    ensure
      trace.disable
      puts output
    end

    private

    CYAN = "\e[36m"
    CLEAR = "\e[0m"
    GREEN = "\e[32m"

    def tracepoint_string(tp, indent)
      parts = []
      parts << "#{'|  ' * indent}"
      parts << "#{CYAN if tp.event == :call}%-8s#{CLEAR}"
      parts << "%s:%-4d %-18s\n"
      parts.join(' ') % [tp.event, tp.path, tp.lineno, tp.defined_class.to_s + '#' + GREEN + tp.method_id.to_s + CLEAR]
    end
  end
end